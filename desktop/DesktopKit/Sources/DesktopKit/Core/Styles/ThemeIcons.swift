import SwiftUI
import UIKit

/// Freedesktop icon names (Icon Naming Specification) for the shell's own controls and
/// places, in fallback order. Symbolic names come first where the control is a glyph;
/// every name here is in `EXACT_ICONS` of themes/guest/ish-apply-style, so the guest
/// renders it for every pack.
enum ThemeIconNames {
    static let launcher = ["view-app-grid-symbolic", "view-app-grid"]

    static let goBack = ["go-previous-symbolic", "go-previous"]
    static let goForward = ["go-next-symbolic", "go-next"]
    static let goUp = ["go-up-symbolic", "go-up"]
    static let newFolder = ["folder-new-symbolic", "folder-new"]
    static let newFile = ["document-new-symbolic", "document-new"]
    static let refresh = ["view-refresh-symbolic", "view-refresh"]
    static let gridView = ["view-grid-symbolic", "view-grid"]
    static let listView = ["view-list-symbolic", "view-list"]
    static let menu = ["open-menu-symbolic", "view-more-symbolic", "open-menu"]
    static let sidebar = ["sidebar-show-symbolic"]
    static let editPath = ["document-edit-symbolic"]
    static let emptyTrash = ["edit-clear-all-symbolic", "user-trash-symbolic"]
    static let eject = ["media-eject-symbolic"]
    static let add = ["list-add-symbolic"]
    static let rootDrive = ["drive-harddisk-symbolic"]

    static let home = ["user-home", "folder-home", "folder"]
    static let desktop = ["user-desktop", "folder-desktop", "folder"]
    static let fileSystem = ["drive-harddisk", "drive-harddisk-system", "computer"]
    static let temporary = ["folder-temp", "folder-recent", "folder"]
    static let trash = ["user-trash", "user-trash-full"]
    static let pictures = ["folder-pictures", "folder"]
    static let iPadFolder = ["folder-remote", "drive-removable-media", "media-removable", "folder"]

    static func windowButton(_ kind: WindowButtonKind, isMaximized: Bool) -> [String] {
        switch kind {
        case .minimize: ["window-minimize-symbolic", "window-minimize"]
        case .maximize: isMaximized ? ["window-restore-symbolic", "window-restore"]
                                    : ["window-maximize-symbolic", "window-maximize"]
        case .close: ["window-close-symbolic", "window-close"]
        }
    }
}

/// A control glyph from the icon pack, in place of `Image(systemName:)`: symbolic icons take
/// the surrounding foreground style like an SF Symbol does, full-colour ones keep their
/// colours. The SF Symbol is drawn when the pack has none of the names (style the
/// fallback with `.font` as before).
struct ThemeGlyph: View {
    let names: [String]
    let symbol: String
    /// The SF Symbol's point size; the pack's icon is drawn in a box of about that size.
    let size: CGFloat
    @Environment(\.desktopIcons) private var icons

    init(_ names: [String], symbol: String, size: CGFloat) {
        self.names = names
        self.symbol = symbol
        self.size = size
    }

    var body: some View {
        if let icon = icons?.icon(names) {
            ThemeIconImageView(icon: icon, side: (size * 1.2).rounded())
        } else {
            Image(systemName: symbol)
        }
    }
}

/// A full-colour icon from the pack (places, file types), or a tinted SF Symbol.
struct ThemeIcon: View {
    let names: [String]
    let symbol: String
    let size: CGFloat
    var tint: Color? = nil
    @Environment(\.desktopIcons) private var icons

    var body: some View {
        if let icon = icons?.icon(names) {
            ThemeIconImageView(icon: icon, side: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.8))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

private struct ThemeIconImageView: View {
    let icon: ThemeIconImage
    let side: CGFloat

    var body: some View {
        Image(uiImage: icon.image)
            .renderingMode(icon.isSymbolic ? .template : .original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}
