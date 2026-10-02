import Network
import Observation
import SwiftUI
import UIKit

struct DesktopNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let date: Date
}

/// Everything `notify` was asked to show, newest first, and do-not-disturb, which keeps the
/// history but suppresses the pop-up toasts.
@Observable @MainActor
final class NotificationCenterModel {
    static let doNotDisturbKey = "desktop.doNotDisturb"
    private static let historyLimit = 100

    private(set) var notices: [DesktopNotice] = []
    private(set) var unreadCount = 0
    var doNotDisturb = UserDefaults.standard.bool(forKey: NotificationCenterModel.doNotDisturbKey) {
        didSet { UserDefaults.standard.set(doNotDisturb, forKey: Self.doNotDisturbKey) }
    }

    func record(_ message: String) {
        notices.insert(DesktopNotice(message: message, date: Date()), at: 0)
        if notices.count > Self.historyLimit { notices.removeLast(notices.count - Self.historyLimit) }
        unreadCount += 1
    }

    func remove(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    func clear() {
        notices.removeAll()
        unreadCount = 0
    }

    func markAllRead() {
        unreadCount = 0
    }
}

/// Battery, network, brightness and keyboard state for quick settings. Monitoring runs only
/// while a panel showing it is on screen.
@Observable @MainActor
final class SystemStatus {
    enum Network: Equatable {
        case offline
        case wifi
        case cellular
        case wired
        case other

        var symbol: String {
            switch self {
            case .offline: "wifi.slash"
            case .wifi: "wifi"
            case .cellular: "antenna.radiowaves.left.and.right"
            case .wired: "cable.connector"
            case .other: "network"
            }
        }

        var title: String {
            switch self {
            case .offline: "Offline"
            case .wifi: "Wi-Fi"
            case .cellular: "Cellular"
            case .wired: "Ethernet"
            case .other: "Connected"
            }
        }
    }

    private(set) var batteryLevel: Float?
    private(set) var batteryState = UIDevice.BatteryState.unknown
    private(set) var network = Network.other
    private(set) var keyboardLanguage: String?
    var brightness: CGFloat = UIScreen.main.brightness {
        didSet { if abs(UIScreen.main.brightness - brightness) > 0.001 { UIScreen.main.brightness = brightness } }
    }

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var users = 0

    func start() {
        users += 1
        guard users == 1 else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     UIScreen.brightnessDidChangeNotification, UITextInputMode.currentInputModeDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let network: Network
            if path.status != .satisfied {
                network = .offline
            } else if path.usesInterfaceType(.wifi) {
                network = .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                network = .wired
            } else if path.usesInterfaceType(.cellular) {
                network = .cellular
            } else {
                network = .other
            }
            Task { @MainActor in self?.network = network }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        monitor?.cancel()
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func refresh() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level < 0 ? nil : level
        batteryState = UIDevice.current.batteryState
        brightness = UIScreen.main.brightness
        keyboardLanguage = UITextInputMode.activeInputModes.first?.primaryLanguage
    }

    var batterySymbol: String {
        guard let batteryLevel else { return "battery.100percent" }
        if batteryState == .charging || batteryState == .full { return "battery.100percent.bolt" }
        switch batteryLevel {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
