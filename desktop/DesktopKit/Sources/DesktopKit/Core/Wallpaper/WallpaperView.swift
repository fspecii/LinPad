import SwiftUI

/// Draws a wallpaper source edge to edge in the chosen fill mode, cross-fading when it
/// changes (a plain cut with Reduce Motion).
struct WallpaperView: View {
    enum Variant {
        case sharp
        /// Blurred and dimmed, behind the overview and the lock screen.
        case blurred
    }

    let store: WallpaperStore
    let source: WallpaperSource
    var variant = Variant.sharp
    var accessibilityID = "desktop.wallpaper"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content(for: source)
                .id(source)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: source)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Wallpaper")
        .accessibilityValue(source.identifier)
        .accessibilityIdentifier(accessibilityID)
    }

    @ViewBuilder
    private func content(for source: WallpaperSource) -> some View {
        switch source {
        case .gradient(let name):
            (DesktopWallpaper(rawValue: name) ?? .midnight).view
                .blur(radius: variant == .blurred ? 30 : 0)
        case .color(let rgb):
            Color(rgb: rgb)
        case .image(let id):
            if variant == .blurred, let image = store.blurred[id] {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let image = store.decoded[id] {
                filled(image)
            } else if let image = store.blurred[id] {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.black
            }
        }
    }

    @ViewBuilder
    private func filled(_ image: UIImage) -> some View {
        switch store.settings.fill {
        case .fill:
            GeometryReader { proxy in
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        case .fit:
            ZStack { Color.black; Image(uiImage: image).resizable().scaledToFit() }
        case .center:
            ZStack { Color.black; Image(uiImage: image) }
        case .tile:
            Image(uiImage: image).resizable(resizingMode: .tile)
        case .stretch:
            Image(uiImage: image).resizable()
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

extension DesktopController {
    /// The wallpaper on `workspace` in the current appearance.
    func wallpaperSource(workspace: Int? = nil) -> WallpaperSource {
        wallpapers.activeSource(workspace: workspace ?? windowManager.currentWorkspace, isDark: isDarkAppearance)
    }

    /// Images to keep decoded: the current workspace's wallpaper, plus every workspace's
    /// while the overview shows them all.
    var visibleWallpaperIDs: Set<String> {
        let workspaces = isOverviewPresented ? Array(0..<windowManager.workspaceCount) : [windowManager.currentWorkspace]
        return Set(workspaces.compactMap { workspace in
            if case .image(let id) = wallpaperSource(workspace: workspace) { return id }
            return nil
        })
    }
}

extension DesktopController {
    private static let wallpaperExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"]

    /// Menu entries the desktop and Files offer for a guest file; "Set as Wallpaper" for
    /// images. The desktop surface and Files render these in their item menus.
    func fileActions(forGuestPath path: String) -> [DesktopMenuItem] {
        guard Self.wallpaperExtensions.contains((path as NSString).pathExtension.lowercased()) else { return [] }
        return [DesktopMenuItem(title: "Set as Wallpaper", symbol: "photo.on.rectangle") { [weak self] in
            Task { await self?.setWallpaper(fromGuestPath: path) }
        }]
    }

    /// Imports a guest image (e.g. one dropped on the desktop) and makes it the wallpaper.
    func setWallpaper(fromGuestPath path: String, target: WallpaperTarget = .both) async {
        do {
            let data: Data
            if let root = (host as? any LinuxGraphicsHost)?.guestRootURL,
               let local = try? Data(contentsOf: root.appendingPathComponent(String(path.drop(while: { $0 == "/" })))) {
                data = local
            } else {
                data = try await host.readFile(path)
            }
            let item = try wallpapers.add(imageData: data, suggestedName: (path as NSString).lastPathComponent,
                                          origin: .guest, attribution: (path as NSString).lastPathComponent)
            wallpapers.set(.image(item.id), target: target, workspace: windowManager.currentWorkspace)
        } catch {
            notify("Couldn't use that image as wallpaper: \(error.localizedDescription)")
        }
    }
}
