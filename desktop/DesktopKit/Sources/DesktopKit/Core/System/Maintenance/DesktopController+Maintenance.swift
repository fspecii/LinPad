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
        startBackupAndDiagnostics()
    }

    /// Scheduled backups, the unclean-exit notice and the hang watchdogs.
    private func startBackupAndDiagnostics() {
        let backup = BackupService.shared(for: host)
        backup.notify = { [weak self] message, action in
            self?.notify(message, action: action, lifetime: action == nil ? nil : .seconds(20))
        }
        backup.restartSession = { [weak self] in
            await self?.restartDesktopSession()
        }
        let diagnostics = DiagnosticsCenter.shared
        diagnostics.beginSession(host: host)
        diagnostics.notify = { [weak self] message, action in
            self?.notify(message, action: action, lifetime: .seconds(30))
        }
        diagnostics.restartSession = { [weak self] in
            await self?.restartDesktopSession()
        }
        diagnostics.showRepair = { [weak self] in
            self?.maintenance.isRepairSheetRequested = true
            self?.showMaintenanceSettings()
        }
        diagnostics.desktopStarted(host: host)
        backup.startScheduling()
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
            CommandMenuItem(id: "maintenance:backup", title: "Back Up Linux Files…", subtitle: "Maintenance",
                            section: .commands, symbol: "externaldrive.badge.timemachine",
                            keywords: "backup back up save export home restore") { [weak self] in
                guard let self else { return }
                BackupService.shared(for: self.host).isBackupSheetRequested = true
                self.showMaintenanceSettings()
            },
            CommandMenuItem(id: "maintenance:diagnostics", title: "Export Diagnostics…", subtitle: "Maintenance",
                            section: .commands, symbol: "stethoscope",
                            keywords: "diagnostics bug report crash log logs") { [weak self] in
                DiagnosticsCenter.shared.isExportSheetRequested = true
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
