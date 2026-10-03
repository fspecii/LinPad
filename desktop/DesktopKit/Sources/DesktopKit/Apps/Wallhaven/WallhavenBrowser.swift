import Observation
import Photos
import SwiftUI
import UIKit

/// Wallpapers saved for later, kept with their metadata so they show offline.
@Observable @MainActor
final class WallhavenFavorites {
    static let storageKey = "wallhaven.favorites"
    private(set) var items: [Wallhaven.Wallpaper]

    init() {
        items = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Wallhaven.Wallpaper].self, from: $0) } ?? []
    }

    func contains(_ wallpaper: Wallhaven.Wallpaper) -> Bool { items.contains { $0.id == wallpaper.id } }

    func toggle(_ wallpaper: Wallhaven.Wallpaper) {
        if let index = items.firstIndex(where: { $0.id == wallpaper.id }) {
            items.remove(at: index)
        } else {
            items.insert(wallpaper, at: 0)
        }
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
}

@Observable @MainActor
final class WallhavenBrowserModel {
    enum Mode: String, CaseIterable, Identifiable {
        case latest = "Latest"
        case toplist = "Toplist"
        case random = "Random"
        case search = "Search"
        case favorites = "Favorites"

        var id: String { rawValue }
    }

    var mode = Mode.latest { didSet { if mode != oldValue { reload() } } }
    var query = Wallhaven.Query()
    var matchesScreen = true
    private(set) var items: [Wallhaven.Wallpaper] = []
    private(set) var isLoading = false
    private(set) var error: Wallhaven.APIError?
    var selection: Int?
    var detail: Wallhaven.Wallpaper?
    var quickLook: Wallhaven.Wallpaper?
    var status: String?

    let client: WallhavenClient
    let favorites = WallhavenFavorites()
    @ObservationIgnored private var lastPage = 1
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(client: WallhavenClient) {
        self.client = client
    }

    static func makeClient() -> WallhavenClient {
        #if DEBUG
        if WallhavenStubProtocol.isEnabled {
            return WallhavenClient(session: WallhavenClient.makeSession(protocolClasses: [WallhavenStubProtocol.self]))
        }
        #endif
        return WallhavenClient()
    }

    /// The device's screen in pixels, landscape: wallpapers at least this big fill it sharply.
    static var screenPixelSize: String {
        let size = UIScreen.main.nativeBounds.size
        return "\(Int(max(size.width, size.height)))x\(Int(min(size.width, size.height)))"
    }

    func reload() {
        loadTask?.cancel()
        items = []
        selection = nil
        error = nil
        query.page = 1
        lastPage = 1
        if mode == .random { query.seed = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }) }
        guard mode != .favorites else {
            items = favorites.items
            return
        }
        loadNextPage()
    }

    func loadMoreIfNeeded(after wallpaper: Wallhaven.Wallpaper) {
        guard mode != .favorites, !isLoading, error == nil, query.page < lastPage,
              items.suffix(8).contains(where: { $0.id == wallpaper.id }) else { return }
        query.page += 1
        loadNextPage()
    }

    private func loadNextPage() {
        var request = query
        request.sorting = switch mode {
        case .latest: .latest
        case .toplist: .toplist
        case .random: .random
        case .search: request.text.isEmpty ? .latest : .relevance
        case .favorites: .latest
        }
        request.atLeast = matchesScreen ? Self.screenPixelSize : nil
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.search(request)
                guard !Task.isCancelled else { return }
                let known = Set(items.map(\.id))
                items += response.data.filter { !known.contains($0.id) }
                lastPage = response.meta.lastPage
                if let seed = response.meta.seed { query.seed = seed }
                error = nil
            } catch let apiError as Wallhaven.APIError {
                error = apiError
            } catch {
                if !Task.isCancelled { self.error = .offline }
            }
            isLoading = false
        }
    }

    func moveSelection(by step: Int, columns: Int) {
        guard !items.isEmpty else { return }
        let current = selection ?? -1
        selection = min(max(current + step, 0), items.count - 1)
        if step > 0, let selection { loadMoreIfNeeded(after: items[selection]) }
        _ = columns
    }

    // MARK: Actions

    func setAsWallpaper(_ wallpaper: Wallhaven.Wallpaper, target: WallpaperTarget, store: WallpaperStore?) async {
        guard let store else { return }
        status = "Downloading \(wallpaper.resolution)…"
        do {
            let id = "wallhaven-\(wallpaper.id)"
            if store.item(id) == nil {
                let data = try await client.download(wallpaper)
                try store.add(imageData: data, suggestedName: "\(id).\(wallpaper.fileExtension)", origin: .wallhaven,
                              attribution: (try? await client.info(id: wallpaper.id))?.attribution ?? wallpaper.attribution,
                              sourceURL: wallpaper.url, id: id)
            }
            store.set(.image(id), target: target, workspace: store.currentWorkspace)
            status = "Wallpaper set"
        } catch {
            status = error.localizedDescription
        }
    }

    /// Saves the original into the guest's ~/Pictures/Wallpapers.
    func downloadToPictures(_ wallpaper: Wallhaven.Wallpaper, host: any LinuxHost) async {
        status = "Downloading \(wallpaper.resolution)…"
        do {
            let data = try await client.download(wallpaper)
            _ = await host.run("mkdir -p /root/Pictures/Wallpapers")
            let path = "/root/Pictures/Wallpapers/wallhaven-\(wallpaper.id).\(wallpaper.fileExtension)"
            try await host.writeFile(path, data: data)
            status = "Saved to ~/Pictures/Wallpapers"
        } catch {
            status = error.localizedDescription
        }
    }

    /// Adds the original to the iPad's Photos with add-only access.
    func saveToPhotos(_ wallpaper: Wallhaven.Wallpaper) async {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
            status = "Allow adding to Photos in Settings to save there."
            return
        }
        do {
            let data = try await client.download(wallpaper)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            status = "Saved to Photos"
        } catch {
            status = error.localizedDescription
        }
    }
}

/// An image from the network through the client's cached session, downsampled for display.
struct RemoteImage: View {
    let url: URL
    let session: URLSession
    var maxPixel: CGFloat = 600
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "wifi.slash").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            do {
                let (data, _) = try await session.data(from: url)
                let maxPixel = maxPixel
                image = await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: cg)
                }.value
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }
}

struct WallpapersAppView: View {
    let context: AppLaunchContext
    @State private var model = WallhavenBrowserModel(client: WallhavenBrowserModel.makeClient())
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopWallpapers) private var wallpapers
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var columns = 4

    private static let cellWidth: CGFloat = 230

    private func search(_ text: String, color: String?) {
        model.query.text = text
        model.query.color = color.flatMap { Wallhaven.colors.contains($0) ? $0 : nil }
        if model.mode == .search { model.reload() } else { model.mode = .search }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            theme.separator.frame(height: 1)
            content
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .accessibilityIdentifier("wallhaven.status")
            }
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear {
            context.window.setTitle("Wallpapers")
            if let query = context.arguments[WallpapersApp.queryArgument] {
                search(query, color: context.arguments[WallpapersApp.colorArgument])
            } else if model.items.isEmpty {
                model.reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WallpapersApp.searchRequested)) { note in
            guard let query = note.userInfo?[WallpapersApp.queryArgument] as? String else { return }
            search(query, color: note.userInfo?[WallpapersApp.colorArgument] as? String)
        }
        .sheet(item: $model.detail) { wallpaper in
            WallhavenDetailView(wallpaper: wallpaper, model: model, host: context.host)
                .environment(\.desktopWallpapers, wallpapers)
                .environment(\.desktopTheme, theme)
        }
        .sheet(item: $model.quickLook) { wallpaper in
            RemoteImage(url: wallpaper.thumbs.large, session: model.client.session, maxPixel: 1600)
                .scaledToFit()
                .frame(minWidth: 700, minHeight: 460)
                .onTapGesture { model.quickLook = nil }
                .onKeyPress(.space) { model.quickLook = nil; return .handled }
                .accessibilityIdentifier("wallhaven.quickLook")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Browse", selection: $model.mode) {
                ForEach(WallhavenBrowserModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("wallhaven.mode")
            if model.mode == .toplist {
                Picker("Range", selection: Binding(get: { model.query.topRange },
                                                   set: { model.query.topRange = $0; model.reload() })) {
                    ForEach(Wallhaven.TopRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if model.mode == .search {
                TextField("Search tags or words", text: $model.query.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .focused($searchFocused)
                    .onSubmit { model.reload() }
                    .accessibilityIdentifier("wallhaven.search")
            }
            Spacer(minLength: 0)
            Menu {
                Toggle("General", isOn: Binding(get: { model.query.general }, set: { model.query.general = $0; model.reload() }))
                Toggle("Anime", isOn: Binding(get: { model.query.anime }, set: { model.query.anime = $0; model.reload() }))
                Toggle("People", isOn: Binding(get: { model.query.people }, set: { model.query.people = $0; model.reload() }))
                Divider()
                Picker("Orientation", selection: Binding(get: { model.query.orientation },
                                                         set: { model.query.orientation = $0; model.reload() })) {
                    Text("Any shape").tag(Wallhaven.Orientation.any)
                    Text("Landscape").tag(Wallhaven.Orientation.landscape)
                    Text("Portrait").tag(Wallhaven.Orientation.portrait)
                }
                Toggle("At least this screen (\(WallhavenBrowserModel.screenPixelSize))",
                       isOn: Binding(get: { model.matchesScreen }, set: { model.matchesScreen = $0; model.reload() }))
                Divider()
                Menu("Color") {
                    Button("Any color") { model.query.color = nil; model.reload() }
                    ForEach(Wallhaven.colors, id: \.self) { hex in
                        Button("#\(hex)") { model.query.color = hex; model.reload() }
                    }
                }
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .accessibilityIdentifier("wallhaven.filters")
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error, model.items.isEmpty {
            ContentUnavailableView {
                Label("Can't load wallpapers", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Try Again") { model.reload() }.buttonStyle(.primary)
            }
            .frame(maxHeight: .infinity)
        } else if model.items.isEmpty && !model.isLoading {
            ContentUnavailableView(model.mode == .favorites ? "No favorites yet" : "Nothing found",
                                   systemImage: "photo.on.rectangle.angled")
                .frame(maxHeight: .infinity)
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let count = max(1, Int((proxy.size.width - 24) / Self.cellWidth))
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: count), spacing: 10) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, wallpaper in
                            thumbnail(wallpaper, isSelected: model.selection == index)
                                .id(wallpaper.id)
                                .onAppear { model.loadMoreIfNeeded(after: wallpaper) }
                        }
                    }
                    .padding(12)
                    if model.isLoading { ProgressView().padding() }
                }
                .onChange(of: model.selection) { _, index in
                    if let index, model.items.indices.contains(index) {
                        withAnimation { scroller.scrollTo(model.items[index].id) }
                    }
                }
            }
            .onAppear { columns = count }
            .onChange(of: count) { _, value in columns = value }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(.leftArrow) { model.moveSelection(by: -1, columns: columns); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(by: 1, columns: columns); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -columns, columns: columns); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: columns, columns: columns); return .handled }
        .onKeyPress(.return) {
            if let index = model.selection { model.detail = model.items[index] }
            return .handled
        }
        .onKeyPress(.space) {
            if let index = model.selection { model.quickLook = model.items[index] }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "f"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.mode = .search
            searchFocused = true
            return .handled
        }
        .onAppear { gridFocused = true }
    }

    private func thumbnail(_ wallpaper: Wallhaven.Wallpaper, isSelected: Bool) -> some View {
        Button { model.detail = wallpaper } label: {
            RemoteImage(url: wallpaper.thumbs.small, session: model.client.session, maxPixel: 480)
                .aspectRatio(3 / 2, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 3)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(wallpaper.resolution)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if model.favorites.contains(wallpaper) {
                        Image(systemName: "heart.fill").foregroundStyle(.white).padding(6).shadow(radius: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .contextMenu {
            Menu("Set as Wallpaper", systemImage: "photo.on.rectangle") {
                ForEach(WallpaperTarget.allCases) { target in
                    Button(target.title) { Task { await model.setAsWallpaper(wallpaper, target: target, store: wallpapers) } }
                }
            }
            Button("Download to Pictures", systemImage: "arrow.down.circle") {
                Task { await model.downloadToPictures(wallpaper, host: context.host) }
            }
            Button(model.favorites.contains(wallpaper) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: "heart") { model.favorites.toggle(wallpaper) }
            Button("Open on Wallhaven", systemImage: "globe") { UIApplication.shared.open(wallpaper.url) }
        }
        .accessibilityLabel("Wallpaper \(wallpaper.resolution)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("wallhaven.thumb.\(wallpaper.id)")
    }
}

struct WallhavenDetailView: View {
    let wallpaper: Wallhaven.Wallpaper
    let model: WallhavenBrowserModel
    let host: any LinuxHost
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopWallpapers) private var wallpapers
    @Environment(\.dismiss) private var dismiss
    @State private var info: Wallhaven.Wallpaper?
    @State private var showsFullResolution = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                RemoteImage(url: wallpaper.thumbs.large, session: model.client.session, maxPixel: 1400).scaledToFit()
                if showsFullResolution {
                    RemoteImage(url: wallpaper.path, session: model.client.session, maxPixel: 2400).scaledToFit()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("wallhaven.preview")
            details.frame(width: 300)
        }
        .frame(minWidth: 820, minHeight: 520)
        .task {
            info = try? await model.client.info(id: wallpaper.id)
            withAnimation { showsFullResolution = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallhaven.detail")
    }

    private var details: some View {
        let shown = info ?? wallpaper
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(shown.resolution).font(.title3.weight(.semibold))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close")
                }
                row("Uploader", shown.uploader?.username ?? "…")
                row("Category", shown.category.capitalized)
                row("File", "\(shown.fileType.replacingOccurrences(of: "image/", with: "").uppercased()) · "
                    + ByteCountFormatter.string(fromByteCount: Int64(shown.fileSize), countStyle: .file))
                if let source = shown.source, !source.isEmpty { row("Source", source) }
                if let tags = shown.tags, !tags.isEmpty {
                    Text(tags.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(theme.secondaryText)
                }
                Text(shown.attribution).font(.caption).foregroundStyle(theme.secondaryText)
                Divider()
                Menu {
                    ForEach(WallpaperTarget.allCases) { target in
                        Button(target.title) {
                            Task { await model.setAsWallpaper(wallpaper, target: target, store: wallpapers) }
                        }
                        .accessibilityIdentifier("wallhaven.set.\(target.rawValue)")
                    }
                } label: {
                    Label("Set as Wallpaper", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(theme.accent.readableLabel)
                }
                .accessibilityIdentifier("wallhaven.setWallpaper")
                actionButton("Download to Pictures", symbol: "arrow.down.circle") {
                    await model.downloadToPictures(wallpaper, host: host)
                }
                actionButton("Save to Photos", symbol: "photo.badge.plus") { await model.saveToPhotos(wallpaper) }
                actionButton(model.favorites.contains(wallpaper) ? "Remove from Favorites" : "Add to Favorites",
                             symbol: "heart") { model.favorites.toggle(wallpaper) }
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("wallhaven.detailStatus")
                }
            }
            .padding(16)
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(theme.secondaryText).frame(width: 70, alignment: .leading)
            Text(value).font(.callout).lineLimit(2).textSelection(.enabled)
        }
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity).frame(height: 34)
                .background(theme.primaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}
