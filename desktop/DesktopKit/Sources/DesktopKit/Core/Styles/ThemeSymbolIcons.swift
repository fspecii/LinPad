import SwiftUI
import UIKit

/// The icon pack's names for the SF Symbols the shell uses in its tray, Quick Settings,
/// Command Menu, Settings and context menus: a view that would draw `symbol` draws the
/// first of these the pack has (ThemeGlyph, ThemedLabel, UIImage.themed) and the symbol
/// only when the pack has none. Every name is in `EXACT_ICONS` of
/// themes/guest/ish-apply-style.
extension ThemeIconNames {
    static let bySymbol: [String: [String]] = [
        "wifi": ["network-wireless-signal-excellent-symbolic", "network-wireless-symbolic"],
        "wifi.slash": ["network-wireless-offline-symbolic", "network-offline-symbolic"],
        "wifi.exclamationmark": ["network-wireless-no-route-symbolic", "network-error-symbolic"],
        "antenna.radiowaves.left.and.right": ["network-cellular-signal-excellent-symbolic", "network-cellular-symbolic"],
        "cable.connector": ["network-wired-symbolic"],
        "network": ["network-transmit-receive-symbolic", "network-wired-symbolic"],
        "battery.100percent": ["battery-full-symbolic", "battery-level-100-symbolic"],
        "battery.100percent.bolt": ["battery-full-charging-symbolic", "battery-level-100-charged-symbolic"],
        "battery.75percent": ["battery-good-symbolic", "battery-level-70-symbolic"],
        "battery.50percent": ["battery-medium-symbolic", "battery-level-50-symbolic", "battery-good-symbolic"],
        "battery.25percent": ["battery-low-symbolic", "battery-level-20-symbolic"],
        "battery.0percent": ["battery-caution-symbolic", "battery-empty-symbolic", "battery-level-0-symbolic"],
        "speaker.slash.fill": ["audio-volume-muted-symbolic"],
        "speaker.wave.1.fill": ["audio-volume-low-symbolic"],
        "speaker.wave.1": ["audio-volume-low-symbolic"],
        "speaker.wave.2.fill": ["audio-volume-medium-symbolic"],
        "speaker.wave.3.fill": ["audio-volume-high-symbolic"],
        "speaker.wave.3": ["audio-volume-high-symbolic"],
        "bell": ["preferences-system-notifications-symbolic", "notifications-symbolic"],
        "bell.fill": ["preferences-system-notifications-symbolic", "notifications-symbolic"],
        "moon.fill": ["notifications-disabled-symbolic", "weather-clear-night-symbolic"],
        "keyboard": ["input-keyboard-symbolic"],
        "keyboard.chevron.compact.down": ["input-keyboard-symbolic"],
        "power": ["system-shutdown-symbolic"],
        "restart": ["system-reboot-symbolic"],
        "lock.fill": ["system-lock-screen-symbolic", "changes-prevent-symbolic"],
        "sun.max.fill": ["display-brightness-symbolic", "weather-clear-symbolic"],
        "sun.max": ["display-brightness-symbolic"],
        "sun.min": ["display-brightness-symbolic"],
        "moon.stars.fill": ["weather-clear-night-symbolic"],
        "speedometer": ["utilities-system-monitor-symbolic", "org.gnome.SystemMonitor-symbolic"],
        "record.circle.fill": ["media-record-symbolic"],
        "mic.fill": ["audio-input-microphone-symbolic"],
        "camera.aperture": ["camera-photo-symbolic"],
        "magnifyingglass": ["system-search-symbolic", "edit-find-symbolic"],
        "rectangle.on.rectangle": ["view-paged-symbolic", "focus-windows-symbolic", "preferences-system-windows-symbolic"],
        "plus.rectangle.on.rectangle": ["window-new-symbolic", "tab-new-symbolic"],
        "rectangle.split.2x2": ["view-grid-symbolic"],
        "rectangle.center.inset.filled": ["zoom-fit-best-symbolic"],
        "doc.text": ["text-x-generic-symbolic"],
        "location": ["mark-location-symbolic"],
        "checkmark.circle": ["object-select-symbolic", "emblem-ok-symbolic"],
        "chevron.left": ["go-previous-symbolic"],
        "chevron.right": ["go-next-symbolic"],
        "grid": ["view-grid-symbolic"],
        "square.grid.3x3": ["view-grid-symbolic"],
        "slider.horizontal.3": ["preferences-system-symbolic", "emblem-system-symbolic"],
        "archivebox.circle": ["package-x-generic-symbolic"],
        "rectangle.3.group": ["view-paged-symbolic", "focus-windows-symbolic", "preferences-system-windows-symbolic"],
        "rectangle.split.2x1": ["view-dual-symbolic", "view-column-symbolic"],
        "square.dashed": ["view-fullscreen-symbolic"],
        "square.grid.2x2": ["view-grid-symbolic"],
        "square.grid.3x3.square": ["view-grid-symbolic"],
        "command": ["system-run-symbolic", "utilities-terminal-symbolic"],
        "link": ["insert-link-symbolic"],
        "paintpalette": ["preferences-desktop-theme-symbolic", "applications-graphics-symbolic"],
        "sparkles": ["starred-symbolic", "emblem-favorite-symbolic"],
        "circle.lefthalf.filled": ["preferences-desktop-appearance-symbolic", "weather-clear-night-symbolic"],
        "macwindow.on.rectangle": ["preferences-desktop-symbolic", "user-desktop-symbolic"],
        "macwindow": ["preferences-system-windows-symbolic", "focus-windows-symbolic"],
        "menubar.rectangle": ["preferences-desktop-symbolic", "user-desktop-symbolic"],
        "info.circle": ["help-about-symbolic", "dialog-information-symbolic"],
        "bolt": ["preferences-system-power-symbolic", "battery-full-charging-symbolic"],
        "bolt.fill": ["preferences-system-power-symbolic", "battery-full-charging-symbolic"],
        "photo.on.rectangle": ["preferences-desktop-wallpaper-symbolic", "image-x-generic-symbolic"],
        "photo.on.rectangle.angled": ["preferences-desktop-wallpaper-symbolic", "image-x-generic-symbolic"],
        "terminal": ["utilities-terminal-symbolic"],
        "textformat": ["preferences-desktop-font-symbolic"],
        "textformat.size": ["preferences-desktop-font-symbolic"],
        "wrench.and.screwdriver": ["applications-engineering-symbolic", "preferences-other-symbolic", "emblem-system-symbolic"],
        "arrow.triangle.2.circlepath": ["software-update-available-symbolic", "view-refresh-symbolic"],
        "arrow.left.arrow.right": ["media-playlist-shuffle-symbolic", "object-flip-horizontal-symbolic"],
        "cursorarrow.motionlines": ["input-mouse-symbolic", "input-touchpad-symbolic"],
        "gearshape": ["preferences-system-symbolic", "emblem-system-symbolic"],
        "doc.on.doc": ["edit-copy-symbolic"],
        "plus.square.on.square": ["edit-copy-symbolic"],
        "scissors": ["edit-cut-symbolic"],
        "doc.on.clipboard": ["edit-paste-symbolic"],
        "trash": ["user-trash-symbolic", "edit-delete-symbolic"],
        "trash.slash": ["edit-delete-symbolic"],
        "pencil": ["document-edit-symbolic"],
        "folder": ["folder-open-symbolic", "folder-symbolic"],
        "folder.badge.plus": ["folder-new-symbolic"],
        "doc.badge.plus": ["document-new-symbolic"],
        "arrow.up.forward.app": ["document-open-symbolic"],
        "arrow.up.right.square": ["document-open-symbolic"],
        "macwindow.badge.plus": ["window-new-symbolic", "tab-new-symbolic"],
        "square.and.arrow.up": ["document-send-symbolic", "emblem-shared-symbolic"],
        "square.and.arrow.down": ["document-save-symbolic"],
        "eye": ["view-reveal-symbolic", "view-visible-symbolic"],
        "arrow.clockwise": ["view-refresh-symbolic"],
        "plus": ["list-add-symbolic"],
        "plus.circle": ["list-add-symbolic"],
        "minus.circle": ["list-remove-symbolic"],
        "xmark": ["window-close-symbolic"],
        "safari": ["web-browser-symbolic", "applications-internet-symbolic"],
        "archivebox": ["package-x-generic-symbolic"],
        "shippingbox": ["package-x-generic-symbolic", "system-software-install-symbolic"],
        "arrow.uturn.backward": ["edit-undo-symbolic"],
        "arrow.uturn.forward": ["edit-redo-symbolic"],
        "checkmark": ["object-select-symbolic"],
        "pin": ["view-pin-symbolic"],
        "pin.slash": ["view-pin-symbolic"],
        "minus.square": ["window-minimize-symbolic"],
        "eject": ["media-eject-symbolic"],
        "arrow.up.left.and.arrow.down.right": ["view-fullscreen-symbolic", "window-maximize-symbolic"],
        "arrow.down.right.and.arrow.up.left": ["view-restore-symbolic", "window-restore-symbolic"],
        "clock": ["preferences-system-time-symbolic"],
        "heart": ["emblem-favorite-symbolic", "starred-symbolic"],
        "heart.fill": ["emblem-favorite-symbolic", "starred-symbolic"],
        "exclamationmark.triangle": ["dialog-warning-symbolic"],
        "eraser": ["edit-clear-symbolic"],
        "arrow.up.arrow.down": ["view-sort-ascending-symbolic"],
        "rectangle.grid.1x2": ["view-list-symbolic"],
        "list.bullet": ["view-list-symbolic"],
        "ellipsis.circle": ["view-more-symbolic", "open-menu-symbolic"],
        "stop.circle": ["media-playback-stop-symbolic"],
        "music.note": ["audio-x-generic-symbolic"],
        "calendar.badge.plus": ["x-office-calendar-symbolic"],
    ]

    static func names(forSymbol symbol: String) -> [String] {
        bySymbol[symbol] ?? []
    }
}

extension DesktopIconStore {
    /// The first of `names` as a ready-made `points` × `points` image for menus and labels,
    /// which draw images at their own size: a template for symbolic icons (menus tint it
    /// like a symbol), full colour otherwise.
    func menuImage(_ names: [String], points: CGFloat = 18) -> UIImage? {
        guard let icon = icon(names) else { return nil }
        return sizedImage(icon, names: names, points: points)
    }
}

/// `Label(title, systemImage:)` with the icon pack's image for the symbol.
struct ThemedLabel: View {
    let title: String
    let systemImage: String
    var points: CGFloat = 18
    @Environment(\.desktopIcons) private var icons

    init(_ title: String, systemImage: String, points: CGFloat = 18) {
        self.title = title
        self.systemImage = systemImage
        self.points = points
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = icons?.menuImage(ThemeIconNames.names(forSymbol: systemImage), points: points) {
                Image(uiImage: image)
            } else {
                Image(systemName: systemImage)
            }
        }
    }
}

extension ThemeGlyph {
    /// The pack's icon for an SF Symbol the shell uses (ThemeIconNames.bySymbol).
    init(symbol: String, size: CGFloat) {
        self.init(ThemeIconNames.names(forSymbol: symbol), symbol: symbol, size: size)
    }
}

extension UIImage {
    /// For UIKit menus: the icon pack's image for an SF Symbol, else the symbol.
    @MainActor
    static func themed(systemName: String, icons: DesktopIconStore? = nil) -> UIImage? {
        (icons ?? DesktopIconStore.active)?.menuImage(ThemeIconNames.names(forSymbol: systemName))
            ?? UIImage(systemName: systemName)
    }
}
