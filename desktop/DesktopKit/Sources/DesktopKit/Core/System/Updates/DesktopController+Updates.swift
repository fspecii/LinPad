import SwiftUI

extension DesktopController {
    var updates: UpdateService { UpdateService.shared(for: host) }

    /// Connects the update service to toasts and Settings, then starts its checks.
    func startUpdateChecks() {
        let service = updates
        service.notify = { [weak self] message, action in
            self?.notify(message, action: action, lifetime: action == nil ? nil : .seconds(20))
        }
        service.showSettings = { [weak self] in
            self?.open(appID: AppID.settings, arguments: [SettingsApp.pageArgument: SettingsApp.updatesPage])
        }
        service.start()
    }
}
