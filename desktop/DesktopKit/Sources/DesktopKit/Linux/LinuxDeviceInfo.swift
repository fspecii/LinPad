import Foundation
import Metal

/// Facts about the iPad for Linux tools (fastfetch's Host, CPU and GPU lines, via the
/// guest's `ish-device-info`). iSH shows the app's UserDefaults as JSON values under
/// /proc/ish/.defaults, so publishing them is a defaults write.
enum LinuxDeviceInfo {
    static let hostModelKey = "linux.hostModel"
    static let chipNameKey = "linux.chipName"
    static let gpuNameKey = "linux.gpuName"
    static let appVersionKey = "linux.appVersion"
    /// "native" or "compatibility" once the kernel runs (fastfetch's JIT line).
    static let cpuEngineKey = "linux.cpuEngine"
    /// The colour theme's display name, or absent for the style's own colours.
    static let colorThemeNameKey = "linux.colorThemeName"

    static func publish(to defaults: UserDefaults = .standard) {
        let identifier = modelIdentifier
        let model = models[identifier]
        defaults.set(model?.name ?? "iPad (\(identifier))", forKey: hostModelKey)
        if let chip = model?.chip {
            defaults.set(chip, forKey: chipNameKey)
        }
        if let gpu = MTLCreateSystemDefaultDevice()?.name {
            defaults.set(gpu, forKey: gpuNameKey)
        }
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            defaults.set(version, forKey: appVersionKey)
        }
    }

    /// "iPad15,3" on a device; the simulator reports the Mac's, so it names the
    /// simulated model in its environment instead.
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Recent iPads with an M-series chip; others show their identifier.
    private static let models: [String: (name: String, chip: String)] = [
        "iPad13,4": ("iPad Pro 11-inch (3rd generation)", "Apple M1"),
        "iPad13,5": ("iPad Pro 11-inch (3rd generation)", "Apple M1"),
        "iPad13,6": ("iPad Pro 11-inch (3rd generation)", "Apple M1"),
        "iPad13,7": ("iPad Pro 11-inch (3rd generation)", "Apple M1"),
        "iPad13,8": ("iPad Pro 12.9-inch (5th generation)", "Apple M1"),
        "iPad13,9": ("iPad Pro 12.9-inch (5th generation)", "Apple M1"),
        "iPad13,10": ("iPad Pro 12.9-inch (5th generation)", "Apple M1"),
        "iPad13,11": ("iPad Pro 12.9-inch (5th generation)", "Apple M1"),
        "iPad13,16": ("iPad Air (5th generation)", "Apple M1"),
        "iPad13,17": ("iPad Air (5th generation)", "Apple M1"),
        "iPad14,3": ("iPad Pro 11-inch (4th generation)", "Apple M2"),
        "iPad14,4": ("iPad Pro 11-inch (4th generation)", "Apple M2"),
        "iPad14,5": ("iPad Pro 12.9-inch (6th generation)", "Apple M2"),
        "iPad14,6": ("iPad Pro 12.9-inch (6th generation)", "Apple M2"),
        "iPad14,8": ("iPad Air 11-inch (M2)", "Apple M2"),
        "iPad14,9": ("iPad Air 11-inch (M2)", "Apple M2"),
        "iPad14,10": ("iPad Air 13-inch (M2)", "Apple M2"),
        "iPad14,11": ("iPad Air 13-inch (M2)", "Apple M2"),
        "iPad15,3": ("iPad Air 11-inch (M3)", "Apple M3"),
        "iPad15,4": ("iPad Air 11-inch (M3)", "Apple M3"),
        "iPad15,5": ("iPad Air 13-inch (M3)", "Apple M3"),
        "iPad15,6": ("iPad Air 13-inch (M3)", "Apple M3"),
        "iPad16,3": ("iPad Pro 11-inch (M4)", "Apple M4"),
        "iPad16,4": ("iPad Pro 11-inch (M4)", "Apple M4"),
        "iPad16,5": ("iPad Pro 13-inch (M4)", "Apple M4"),
        "iPad16,6": ("iPad Pro 13-inch (M4)", "Apple M4"),
    ]
}
