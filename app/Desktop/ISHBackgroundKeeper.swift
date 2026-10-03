import CoreLocation
import DesktopKit
import Foundation
import os

/// Settings › Background on the iPad side. iPadOS suspends LinPad about 30 s after it
/// leaves the screen; the whole emulator stops with it. Two background modes keep it
/// running, both declared in Info.plist (UIBackgroundModes):
///
/// * `audio`: while the audio session plays (ISHAudioBridge). "Off" gives the session up
///   on leaving the screen so iPadOS suspends LinPad even with music playing.
/// * `location`: while location updates run. "Always" starts coarse updates in the
///   foreground (iPadOS only lets them start there) with a CLBackgroundActivitySession,
///   which keeps them going with When In Use permission; the blue indicator shows.
///   The fixes are thrown away. Same idea as iSH's `cat /dev/location > /dev/null &`
///   (github.com/ish-app/ish/wiki/Running-in-background) and Blink's `geo track`.
///
/// The permission prompt only ever appears from the user's "Allow Location…" in Settings.
@MainActor
final class ISHBackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = ISHBackgroundKeeper()

    /// UI tests: "allowed", "denied", "notDetermined" or "unavailable" instead of Core
    /// Location, so no permission prompt can appear on a test machine.
    static let mockAccessKey = "lifecycle.mockLocationAccess"

    private let log = Logger(subsystem: "app.ish.desktop", category: "background")
    private var manager: CLLocationManager?
    private var activitySession: AnyObject?
    private var isUpdating = false
    private var mode = BackgroundExecution.defaultValue
    private var inBackground = false
    private var authorizationWaiters: [CheckedContinuation<BackgroundLocationAccess, Never>] = []

    private var mockAccess: BackgroundLocationAccess? {
        #if DEBUG || DESKTOP_AUTOMATION
        switch UserDefaults.standard.string(forKey: Self.mockAccessKey) {
        case "allowed": return .allowed
        case "denied": return .denied
        case "notDetermined": return .notDetermined
        case "unavailable": return .unavailable
        default: return nil
        }
        #else
        return nil
        #endif
    }

    var access: BackgroundLocationAccess {
        if let mockAccess { return mockAccess }
        return Self.access(for: locationManager.authorizationStatus)
    }

    private static func access(for status: CLAuthorizationStatus) -> BackgroundLocationAccess {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        case .denied: .denied
        case .restricted: .unavailable
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    /// Created on first use; creating one shows no prompt.
    private var locationManager: CLLocationManager {
        if let manager { return manager }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        self.manager = manager
        return manager
    }

    func requestAccess() async -> BackgroundLocationAccess {
        if let mockAccess { return mockAccess }
        guard access == .notDetermined else { return access }
        return await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func apply(_ mode: BackgroundExecution, inBackground: Bool) {
        self.mode = mode
        self.inBackground = inBackground
        // Off: give the audio session up when leaving the screen, so iPadOS suspends LinPad.
        ISHAudioBridge.shared.setBackgroundPlaybackAllowed(mode != .off, inBackground: inBackground)
        updateLocation()
    }

    private func updateLocation() {
        let wanted = mode == .always && access == .allowed && mockAccess == nil
        if wanted && !isUpdating {
            // Updates can only begin in the foreground; begun there they keep running.
            guard !inBackground else { return }
            let manager = locationManager
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            activitySession = CLBackgroundActivitySession()
            isUpdating = true
            log.info("keeping Linux running in the background (location)")
        } else if !wanted && isUpdating {
            manager?.stopUpdatingLocation()
            manager?.allowsBackgroundLocationUpdates = false
            (activitySession as? CLBackgroundActivitySession)?.invalidate()
            activitySession = nil
            isUpdating = false
            log.info("background location off")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            let access = Self.access(for: status)
            if access != .notDetermined {
                let waiters = authorizationWaiters
                authorizationWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: access) }
            }
            updateLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension ISHLinuxHost: LinuxLifecycleHosting {
    func flushFilesystem() async {
        await Task.detached(priority: .userInitiated) {
            _ = ish_fakefs_flush()
        }.value
    }

    func applyBackgroundExecution(_ mode: BackgroundExecution, inBackground: Bool) {
        ISHBackgroundKeeper.shared.apply(mode, inBackground: inBackground)
    }

    var backgroundLocationAccess: BackgroundLocationAccess {
        ISHBackgroundKeeper.shared.access
    }

    func requestBackgroundLocationAccess() async -> BackgroundLocationAccess {
        await ISHBackgroundKeeper.shared.requestAccess()
    }

    func resumeAfterBackground() {
        ISHAudioBridge.shared.resumeAfterBackground()
        ISHMicBridge.shared.resumeAfterBackground()
    }
}
