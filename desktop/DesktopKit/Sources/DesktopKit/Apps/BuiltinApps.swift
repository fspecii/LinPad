import Foundation

/// The apps that ship with the desktop, in launcher order.
public enum BuiltinApps {
    public static func all() -> [DesktopAppDescriptor] {
        [
            TerminalApp.descriptor(),
            FilesApp.descriptor(),
            TextEditorApp.descriptor(),
            BrowserApp.descriptor(),
            TaskManagerApp.descriptor(),
            PackagesApp.descriptor(),
            SettingsApp.descriptor(),
            WallpapersApp.descriptor(),
            ThemesApp.descriptor(),
            CalendarApp.descriptor(),
        ]
    }
}
