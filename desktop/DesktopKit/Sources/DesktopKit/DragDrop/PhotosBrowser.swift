import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The iPad photo library as a Files place. Photos stay in PhotoKit until they are used:
/// opening, dragging or importing one exports the original to a host cache and copies it
/// into the guest through the transfer service.
@Observable @MainActor
final class PhotosLibraryModel {
    struct Album: Identifiable, Hashable {
        let id: String
        let title: String
    }

    static let recentsID = "recents"
    /// Where opened photos are materialized in the guest.
    static let guestCache = "/tmp/ish-photos"

    private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var albums: [Album] = []
    var albumID = PhotosLibraryModel.recentsID
    private(set) var assets: [PHAsset] = []
    var selection: Set<String> = []
    private(set) var busy: String?
    var errorMessage: String?

    @ObservationIgnored let imageManager = PHCachingImageManager()
    @ObservationIgnored private var exported: [String: URL] = [:]

    var canBrowse: Bool { status == .authorized || status == .limited }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        reload()
    }

    func reload() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canBrowse else { return }
        var list = [Album(id: Self.recentsID, title: "Recents")]
        let favorites = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        favorites.enumerateObjects { collection, _, _ in list.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "Favorites")) }
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        user.enumerateObjects { collection, _, _ in list.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album")) }
        albums = list
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result: PHFetchResult<PHAsset>
        if albumID != Self.recentsID,
           let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        var fetched: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        assets = fetched
        selection.formIntersection(Set(fetched.map(\.localIdentifier)))
    }

    func presentLimitedPicker() {
        guard let top = HostPresenter.topViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    var selectedAssets: [PHAsset] { assets.filter { selection.contains($0.localIdentifier) } }

    func targets(for asset: PHAsset) -> [PHAsset] {
        selection.contains(asset.localIdentifier) ? selectedAssets : [asset]
    }

    // MARK: Exporting

    static func fileName(of asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "\(asset.localIdentifier.prefix(8)).jpg"
    }

    /// The original as a host file, exported once per launch.
    func export(_ asset: PHAsset) async throws -> URL {
        if let url = exported[asset.localIdentifier], FileManager.default.fileExists(atPath: url.path) { return url }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video || $0.type == .audio }) ?? resources.first else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let directory = try HostStaging.makeDirectory(prefix: "Photos")
        let url = directory.appendingPathComponent(resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        exported[asset.localIdentifier] = url
        return url
    }

    /// Copies photos into a guest folder; returns their guest paths.
    func importToGuest(_ assets: [PHAsset], directory: String, host: any LinuxHost) async throws -> [String] {
        let transfer = GuestTransferService(host: host)
        let mkdir = await host.run("mkdir -p -- \(directory.shellQuoted)", cwd: nil, stdin: nil)
        guard mkdir.succeeded else { throw LinuxHostError.commandFailed(mkdir) }
        var paths: [String] = []
        for (index, asset) in assets.enumerated() {
            busy = assets.count > 1 ? "Copying \(index + 1) of \(assets.count)…" : "Copying…"
            let url = try await export(asset)
            paths.append(try await transfer.importItem(at: url, into: directory))
        }
        busy = nil
        return paths
    }

    /// A drag item: the original as a file (for any drop target, other apps included).
    func dragProvider(for asset: PHAsset) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = Self.fileName(of: asset)
        let type = UTType(filenameExtension: AppPath.pathExtension(Self.fileName(of: asset))) ?? (asset.mediaType == .video ? .movie : .image)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
            Task { @MainActor in
                do {
                    guard let self else { throw CocoaError(.fileReadUnknown) }
                    completion(try await self.export(asset), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

/// "Save to Photos" for images and videos in the guest (add-only access).
@MainActor
enum PhotosSaver {
    static func canSave(_ name: String) -> Bool {
        guard let type = UTType(filenameExtension: AppPath.pathExtension(name)) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    static func save(_ entries: [FileEntry], transfer: GuestTransferService) async throws -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var saved = 0
        for entry in entries where canSave(entry.name) {
            let url = try await transfer.exportItem(entry.path, isDirectory: false)
            let isVideo = UTType(filenameExtension: AppPath.pathExtension(entry.name))?.conforms(to: .movie) ?? false
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            saved += 1
        }
        return saved
    }
}

/// The Photos place's content: albums, a thumbnail grid, and the photo actions.
struct PhotosBrowserView: View {
    let model: PhotosLibraryModel
    let host: any LinuxHost
    let desktop: any DesktopActions
    let isFocused: Bool

    @Environment(\.desktopTheme) private var theme
    @State private var keyToken = 0

    var body: some View {
        VStack(spacing: 0) {
            if !model.canBrowse {
                permissionView
            } else {
                header
                if model.status == .limited {
                    InlineBanner(kind: .info, message: "Files can see only the photos you selected.",
                                 actionTitle: "Select More…", action: { model.presentLimitedPicker() })
                }
                grid
            }
        }
        .background {
            KeyCommandHost(isActive: isFocused && model.canBrowse, focusToken: keyToken, onKey: handle(_:), onType: { _ in })
                .frame(width: 1, height: 1)
        }
        .task { model.reload() }
        .onChange(of: model.albumID) { _, _ in model.reload() }
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(theme.secondaryText)
            Text("Photos").font(.title3.weight(.semibold))
            if model.status == .notDetermined {
                Text("Browse your photo library here and open photos in Linux apps.")
                    .foregroundStyle(theme.secondaryText)
                Button("Allow Access to Photos") { Task { await model.requestAccess() } }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("photos.allow")
            } else {
                Text("Access to Photos is off. Turn it on in Settings › iSH › Photos.")
                    .foregroundStyle(theme.secondaryText)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Picker("Album", selection: Binding(get: { model.albumID }, set: { model.albumID = $0 })) {
                ForEach(model.albums) { album in Text(album.title).tag(album.id) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("photos.album")
            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundStyle(theme.secondaryText)
            }
            Text("\(model.assets.count) items").font(.caption).foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 6)], spacing: 6) {
                ForEach(model.assets, id: \.localIdentifier) { asset in
                    PhotoThumbnail(asset: asset, manager: model.imageManager,
                                   isSelected: model.selection.contains(asset.localIdentifier))
                        .onTapGesture(count: 2) { open(asset) }
                        .simultaneousGesture(TapGesture().onEnded {
                            if KeyboardModifiers.isCommandDown || KeyboardModifiers.isShiftDown {
                                if model.selection.contains(asset.localIdentifier) { model.selection.remove(asset.localIdentifier) }
                                else { model.selection.insert(asset.localIdentifier) }
                            } else {
                                model.selection = [asset.localIdentifier]
                            }
                            keyToken += 1
                        })
                        .onDrag {
                            if !model.selection.contains(asset.localIdentifier) { model.selection = [asset.localIdentifier] }
                            return model.dragProvider(for: asset)
                        }
                        .contextMenu { menu(asset) }
                        .accessibilityIdentifier("photos.asset")
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func menu(_ asset: PHAsset) -> some View {
        let targets = model.targets(for: asset)
        Button { open(asset) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        let apps = OpenWithCatalog.shared.linuxApplications(
            for: OpenWithCatalog.shared.mimeType(for: PhotosLibraryModel.fileName(of: asset), isDirectory: false))
        if !apps.isEmpty {
            Menu {
                ForEach(apps) { app in Button(app.name) { open(asset, with: app) } }
            } label: { Label("Open With", systemImage: "arrow.up.right.square") }
        }
        Button { quickLook(targets) } label: { Label("Quick Look", systemImage: "eye") }
        Divider()
        Button { importToPictures(targets) } label: { Label("Import to ~/Pictures", systemImage: "square.and.arrow.down") }
        Button { share(targets) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
    }

    private func handle(_ key: FileKey) {
        switch key {
        case .quickLook: quickLook(model.selectedAssets)
        case .open: if let first = model.selectedAssets.first { open(first) }
        case .selectAll: model.selection = Set(model.assets.map(\.localIdentifier))
        case .escape: model.selection = []
        default: break
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { desktop.notify("Photos: \(error.localizedDescription)") }
        }
    }

    private func open(_ asset: PHAsset, with app: OpenWithCatalog.Application? = nil) {
        run {
            guard let path = try await model.importToGuest([asset], directory: PhotosLibraryModel.guestCache, host: host).first else { return }
            if let app {
                desktop.open(appID: LinuxAppID.prefix + OpenWithCatalog.command(exec: app.exec, path: path), arguments: [:])
                return
            }
            switch OpenWithCatalog.shared.defaultOpen(for: AppPath.lastComponent(path)) {
            case .linux(let app): desktop.open(appID: LinuxAppID.prefix + OpenWithCatalog.command(exec: app.exec, path: path), arguments: [:])
            default: quickLook([asset])
            }
        }
    }

    private func quickLook(_ assets: [PHAsset]) {
        if QuickLookPresenter.shared.isPresenting {
            QuickLookPresenter.shared.dismiss()
            return
        }
        guard !assets.isEmpty else { return }
        run {
            var urls: [URL] = []
            for asset in assets { urls.append(try await model.export(asset)) }
            QuickLookPresenter.shared.preview(urls)
        }
    }

    private func importToPictures(_ assets: [PHAsset]) {
        run {
            let pictures = AppPath.join(host.homeDirectory, "Pictures")
            let paths = try await model.importToGuest(assets, directory: pictures, host: host)
            desktop.notify(paths.count == 1 ? "Imported to \(paths[0])" : "Imported \(paths.count) items to ~/Pictures")
        }
    }

    private func share(_ assets: [PHAsset]) {
        run {
            var urls: [URL] = []
            for asset in assets { urls.append(try await model.export(asset)) }
            HostPresenter.share(urls)
        }
    }
}

private struct PhotoThumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let isSelected: Bool
    @State private var image: UIImage?
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(theme.primaryText.opacity(0.06))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
            if asset.mediaType == .video {
                Text(Duration.seconds(asset.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(4).shadow(radius: 2)
            }
        }
        .frame(height: 120)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.accent, lineWidth: isSelected ? 3 : 0))
        .contentShape(Rectangle())
        .onAppear {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            manager.requestImage(for: asset, targetSize: CGSize(width: 300, height: 300), contentMode: .aspectFill,
                                 options: options) { result, _ in
                Task { @MainActor in image = result }
            }
        }
    }
}
