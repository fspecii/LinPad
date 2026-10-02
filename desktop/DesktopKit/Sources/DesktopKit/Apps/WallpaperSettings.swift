import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Wallpaper: built-ins, gradients and colors, the library (Photos, Files, the
/// guest's Pictures, Wallhaven), fill mode, per-workspace and light/dark choice, slideshow.
struct WallpaperSettingsSection: View {
    let store: WallpaperStore
    let host: any LinuxHost
    @Environment(\.desktopTheme) private var theme
    @State private var target = WallpaperTarget.both
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var showsGuest = false
    @State private var customColor = Color(red: 0.12, green: 0.14, blue: 0.2)
    @State private var errorMessage: String?

    private static let colors: [UInt32] = [0x1C1C1E, 0x0F2A44, 0x1D3B2A, 0x3B1D3A, 0x4A2B12, 0x5A5A5E]
    private static let intervals: [(String, TimeInterval)] = [
        ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900), ("1 hour", 3600), ("1 day", 86400),
    ]

    var body: some View {
        SettingsSection(title: "Wallpaper", symbol: "photo.on.rectangle") {
            current
            ThemedSeparator()
            SettingsRow(title: "Apply to") {
                Picker("Apply to", selection: $target) {
                    ForEach(WallpaperTarget.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("wallpaper.target")
            }
            Text("Images").font(.subheadline.weight(.semibold)).foregroundStyle(theme.secondaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                ForEach(store.library) { item in
                    imageTile(item)
                }
            }
            HStack(spacing: 10) {
                addButton("Photos", symbol: "photo") { showsPhotos = true }
                    .accessibilityIdentifier("wallpaper.addPhotos")
                addButton("Files", symbol: "folder") { showsFiles = true }
                addButton("Linux Pictures", symbol: "externaldrive") { showsGuest = true }
            }
            Text("Gradients and colors").font(.subheadline.weight(.semibold)).foregroundStyle(theme.secondaryText)
            HStack(spacing: 10) {
                ForEach(DesktopWallpaper.allCases, id: \.self) { gradient in
                    swatch(.gradient(gradient.rawValue)) { gradient.view }
                        .accessibilityLabel(gradient.rawValue.capitalized)
                        .accessibilityIdentifier("wallpaper.gradient.\(gradient.rawValue)")
                }
                ForEach(Self.colors, id: \.self) { rgb in
                    swatch(.color(rgb)) { Color(rgb: rgb) }
                        .accessibilityLabel(String(format: "Color %06X", rgb))
                }
                ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: customColor) { _, color in apply(.color(color.rgbValue)) }
            }
            ThemedSeparator()
            SettingsRow(title: "Fill") {
                Picker("Fill", selection: Binding(get: { store.settings.fill },
                                                  set: { fill in store.update { $0.fill = fill } })) {
                    ForEach(WallpaperFill.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsRow(title: "Different wallpaper per workspace") {
                Toggle("Per workspace", isOn: Binding(get: { store.settings.usesPerWorkspace },
                                                      set: { on in store.update { $0.usesPerWorkspace = on } }))
                    .labelsHidden().tint(theme.accent)
            }
            ThemedSeparator()
            slideshow
            if let errorMessage {
                InlineBanner(kind: .error, message: errorMessage)
            }
        }
        .photosPicker(isPresented: $showsPhotos, selection: Binding(get: { nil }, set: { item in
            if let item { importPhoto(item) }
        }), matching: .images, photoLibrary: .shared())
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image]) { result in
            importFile(result)
        }
        .sheet(isPresented: $showsGuest) {
            GuestPicturesPicker(host: host) { url in
                showsGuest = false
                importGuest(url)
            }
        }
    }

    // MARK: Pieces

    private var current: some View {
        let source = store.activeSource(workspace: store.currentWorkspace, isDark: store.isDark)
        return HStack(spacing: 14) {
            WallpaperView(store: store, source: source, accessibilityID: "wallpaper.preview")
                .frame(width: 160, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Current wallpaper").font(.callout.weight(.semibold))
                Text(store.isDark ? "Dark appearance" : "Light appearance")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                if case .image(let id) = source, let item = store.item(id), let attribution = item.attribution {
                    if let url = item.sourceURL {
                        Link(attribution, destination: url).font(.caption)
                    } else {
                        Text(attribution).font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wallpaper.current")
    }

    private var slideshow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(title: "Slideshow") {
                Toggle("Slideshow", isOn: Binding(get: { store.settings.slideshow.isEnabled },
                                                  set: { on in store.update { $0.slideshow.isEnabled = on } }))
                    .labelsHidden().tint(theme.accent)
            }
            if store.settings.slideshow.isEnabled {
                SettingsRow(title: "Pictures") {
                    Picker("Pictures", selection: Binding(get: { store.settings.slideshow.source },
                                                          set: { source in store.update { $0.slideshow.source = source } })) {
                        Text("Favorites").tag(WallpaperSlideshow.Source.favorites)
                        Text("All images").tag(WallpaperSlideshow.Source.library)
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
                SettingsRow(title: "Change every") {
                    Picker("Interval", selection: Binding(get: { store.settings.slideshow.interval },
                                                          set: { value in store.update { $0.slideshow.interval = value } })) {
                        ForEach(Self.intervals, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.menu)
                }
                SettingsRow(title: "Shuffle") {
                    Toggle("Shuffle", isOn: Binding(get: { store.settings.slideshow.shuffle },
                                                    set: { on in store.update { $0.slideshow.shuffle = on } }))
                        .labelsHidden().tint(theme.accent)
                }
                Text("Mark images as favorites with a long press or right click.")
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func imageTile(_ item: WallpaperItem) -> some View {
        let isCurrent = store.activeSource(workspace: store.currentWorkspace, isDark: store.isDark) == .image(item.id)
        return Button { apply(.image(item.id)) } label: {
            WallpaperThumbnail(store: store, item: item)
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isCurrent ? theme.accent : theme.separator, lineWidth: isCurrent ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite {
                        Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(.white)
                            .padding(5).shadow(radius: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .contextMenu {
            Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: item.isFavorite ? "heart.slash" : "heart") { store.toggleFavorite(item.id) }
            ForEach(WallpaperTarget.allCases) { target in
                Button("Set for \(target.title)") { store.set(.image(item.id), target: target, workspace: store.currentWorkspace) }
            }
            if item.origin != .builtIn {
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive) { store.remove(item.id) }
            }
        }
        .accessibilityLabel(item.attribution ?? item.id)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("wallpaper.item.\(item.id)")
    }

    private func swatch<Content: View>(_ source: WallpaperSource, @ViewBuilder content: () -> Content) -> some View {
        let isCurrent = store.activeSource(workspace: store.currentWorkspace, isDark: store.isDark) == source
        return Button { apply(source) } label: {
            content()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isCurrent ? theme.accent : theme.separator, lineWidth: isCurrent ? 3 : 1)
                }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func addButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).frame(height: 32)
                .background(theme.primaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: Importing

    private func apply(_ source: WallpaperSource) {
        store.set(source, target: target, workspace: store.currentWorkspace)
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let type = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let added = try store.add(imageData: data, suggestedName: "photo.\(type)", origin: .photos)
                apply(.image(added.id))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let added = try store.add(imageData: try Data(contentsOf: url), suggestedName: url.lastPathComponent,
                                      origin: .files)
            apply(.image(added.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importGuest(_ url: URL) {
        do {
            let added = try store.add(imageData: try Data(contentsOf: url), suggestedName: url.lastPathComponent,
                                      origin: .guest)
            apply(.image(added.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A small thumbnail of a library image, made once by the cache.
struct WallpaperThumbnail: View {
    let store: WallpaperStore
    let item: WallpaperItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: item.id) {
            let cache = store.cache
            let item = item
            image = await Task.detached(priority: .utility) {
                cache.downsampled(fileName: item.fileName, id: item.id, maxPixel: 320, suffix: "thumb")
            }.value
        }
    }
}

/// Images in the guest's ~/Pictures and the system background folders, read straight from
/// the guest filesystem.
struct GuestPicturesPicker: View {
    let host: any LinuxHost
    let pick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.desktopTheme) private var theme
    @State private var images: [URL] = []

    static let folders = ["root/Pictures", "usr/share/backgrounds", "usr/share/wallpapers", "usr/share/ukui-wallpapers"]
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    var body: some View {
        NavigationStack {
            Group {
                if images.isEmpty {
                    ContentUnavailableView("No pictures", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Put images in ~/Pictures to see them here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(images, id: \.self) { url in
                                Button { pick(url) } label: {
                                    VStack(spacing: 4) {
                                        LocalImageThumbnail(url: url).frame(height: 96)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Linux Pictures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { images = findImages() }
    }

    private func findImages() -> [URL] {
        guard let root = (host as? any LinuxGraphicsHost)?.guestRootURL else { return [] }
        let fileManager = FileManager.default
        return Self.folders.flatMap { folder -> [URL] in
            guard let enumerator = fileManager.enumerator(at: root.appendingPathComponent(folder),
                                                          includingPropertiesForKeys: nil) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter { Self.extensions.contains($0.pathExtension.lowercased()) }
        }
        .prefix(200)
        .map { $0 }
    }
}

private struct LocalImageThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .utility) {
                WallpaperImageCache.thumbnail(url: url, maxPixel: 300).map(UIImage.init(cgImage:))
            }.value
        }
    }
}

extension Color {
    /// 0xRRGGBB of the color in sRGB.
    var rgbValue: UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
