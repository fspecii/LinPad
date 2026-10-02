import SwiftUI

extension DesktopController {
    var maintenance: SystemMaintenanceService { SystemMaintenanceService.shared(for: host) }

    /// Connects Settings › Maintenance to toasts and the Linux session, then runs the
    /// silent repair if the app bundles a newer repair kit than the guest applied.
    func startMaintenance() {
        let service = maintenance
        service.notify = { [weak self] message, action in
            self?.notify(message, action: action, lifetime: action == nil ? nil : .seconds(20))
        }
        service.restartSession = { [weak self] in
            await self?.restartDesktopSession()
        }
        service.showSettings = { [weak self] in
            self?.showMaintenanceSettings()
        }
        Task { await service.runAutomaticRepairIfNeeded() }
    }

    func showMaintenanceSettings() {
        open(appID: AppID.settings, arguments: [SettingsApp.pageArgument: SettingsApp.maintenancePage])
    }

    func maintenanceCommandItems() -> [CommandMenuItem] {
        [
            CommandMenuItem(id: "maintenance:repair", title: "Repair System…", subtitle: "Maintenance",
                            section: .commands, symbol: "bandage",
                            keywords: "repair fix maintenance firefox youtube video broken") { [weak self] in
                self?.maintenance.isRepairSheetRequested = true
                self?.showMaintenanceSettings()
            },
            CommandMenuItem(id: "maintenance:reset", title: "Reset to Factory…", subtitle: "Maintenance",
                            section: .commands, symbol: "arrow.counterclockwise",
                            keywords: "reset factory reinstall erase maintenance") { [weak self] in
                self?.maintenance.isResetSheetRequested = true
                self?.showMaintenanceSettings()
            },
        ]
    }
}
