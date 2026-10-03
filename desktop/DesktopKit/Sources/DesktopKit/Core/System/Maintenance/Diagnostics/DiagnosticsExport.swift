import Darwin
import Foundation
import Observation
import os
import UIKit

/// One file of a diagnostics export, shown on the review screen before anything is saved.
struct DiagnosticsItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    /// The file name inside the zip.
    let fileName: String
    /// Already redacted.
    var text: String
    var isIncluded = true
}

/// Settings › Maintenance › Export Diagnostics: gathers versions, memory, logs and crash
/// reports, redacts them, lets the user review and untick items, then zips what is left for
/// the share sheet. Nothing is sent anywhere by LinPad itself.
@Observable @MainActor
final class DiagnosticsExportModel {
    enum State: Equatable {
        case idle
        case collecting
        case review
        case exported(URL)
        case failed(String)
    }

    private(set) var state = State.idle
    var items: [DiagnosticsItem] = []

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private let center: DiagnosticsCenter
    @ObservationIgnored private let outputDirectory: URL

    init(host: any LinuxHost, center: DiagnosticsCenter? = nil, outputDirectory: URL? = nil) {
        self.host = host
        self.center = center ?? .shared
        self.outputDirectory = outputDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    static let guestTimeout: TimeInterval = 8
    static let maxLogBytes = 256 << 10

    func collect() async {
        state = .collecting
        let guestAnswers = await DiagnosticsCenter.answers(host, within: 5)
        let passwd = guestAnswers ? await guest("cat /etc/passwd") : ""
        let guestHostName = guestAnswers ? await guest("hostname").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let redactor = DiagnosticsRedactor(
            userNames: DiagnosticsRedactor.userNames(fromPasswd: passwd),
            deviceNames: [UIDevice.current.name, host.hostName, guestHostName].filter { !$0.isEmpty },
            iPadFolders: (host as? HostDirectoryMounting).map { Array($0.mountedHostDirectories) } ?? [])

        var collected: [DiagnosticsItem] = []
        func add(_ id: String, _ title: String, _ detail: String, _ file: String, _ text: String) {
            guard !text.isEmpty else { return }
            collected.append(DiagnosticsItem(id: id, title: title, detail: detail, fileName: file, text: redactor.redact(text)))
        }

        add("info", "LinPad and iPad", "App, Linux system and repair kit versions, iPad model and iPadOS version, fast mode, memory and storage.",
            "info.txt", await infoText(guestAnswers: guestAnswers))
        add("events", "Recent problems", "Unexpected exits, stalls and crash reports LinPad noticed, with dates.",
            "events.txt", eventsText())
        let provider = host as? LinuxDiagnosticsProviding
        if let provider {
            let empty = "(empty: nothing was logged since LinPad started)"
            add("kernel-log", "Linux kernel log", "The newest messages of the emulator's kernel log (what dmesg shows).",
                "kernel-log.txt", provider.emulatorLog(diagnostic: false, maxBytes: Self.maxLogBytes).nonEmpty ?? empty)
            add("emulator-log", "Emulator diagnostic log", "Messages normally hidden: network waits, unsupported system calls.",
                "emulator-diagnostic-log.txt", provider.emulatorLog(diagnostic: true, maxBytes: Self.maxLogBytes).nonEmpty ?? empty)
        } else if guestAnswers {
            add("kernel-log", "Linux kernel log", "The newest messages of dmesg.", "kernel-log.txt", await guest("dmesg 2>&1 | tail -c \(Self.maxLogBytes)"))
        }
        add("crash-logs", "Emulator crash logs", "What the emulator logged when it last stopped with a fatal error.",
            "emulator-crashes.txt", directoryText(center.crashLogsDirectory) + fileText(center.logSnapshotURL, title: "log snapshot before the last exit"))
        add("metrickit", "Crash and hang reports from iPadOS", "MetricKit reports: crashes, hangs, heavy CPU or disk use, with call stacks of LinPad's code.",
            "metrickit.json.txt", directoryText(center.payloadsDirectory))
        add("ishwl", "Linux desktop session log", "The log of ishwl, the bridge that shows Linux windows.",
            "ishwl.log", guestFileTail("/tmp/ishwl.log"))
        if guestAnswers {
            add("meminfo", "Linux memory", "/proc/meminfo inside Linux.", "guest-meminfo.txt", await guest("cat /proc/meminfo"))
            add("packages", "Installed packages", "The Alpine packages installed in Linux, with versions (no files).",
                "packages.txt", await guest("echo '# world'; cat /etc/apk/world; echo; echo '# installed'; apk info -v 2>/dev/null | sort"))
        }
        add("boot", "Boot timings", "How long the last start of Linux took.", "boot-stats.txt",
            (try? String(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("boot-stats.txt"), encoding: .utf8)) ?? "")
        items = collected
        state = .review
    }

    func export() {
        do {
            state = .exported(try Self.writeZip(items: items.filter(\.isIncluded), to: outputDirectory, date: Date()))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reset() {
        state = .idle
        items = []
    }

    /// The included items as text files in a folder, zipped by the system (an
    /// NSFileCoordinator "for uploading" read makes a zip of a folder).
    static func writeZip(items: [DiagnosticsItem], to directory: URL, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "linpad-diagnostics-\(formatter.string(from: date))"
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var index = "LinPad diagnostics, \(date.formatted(.iso8601)). Paths in home folders, user and device names and e-mail addresses were removed.\n\n"
        for item in items {
            try Data(item.text.utf8).write(to: folder.appendingPathComponent(item.fileName))
            index += "\(item.fileName): \(item.title). \(item.detail)\n"
        }
        try Data(index.utf8).write(to: folder.appendingPathComponent("README.txt"))
        let zip = directory.appendingPathComponent(name + ".zip")
        try? FileManager.default.removeItem(at: zip)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { temporary in
            do { try FileManager.default.copyItem(at: temporary, to: zip) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return zip
    }

    // MARK: Sources

    private func guest(_ command: String) async -> String {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor [host] in
                let result = await host.run(command)
                return result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.guestTimeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? "(Linux did not answer within \(Int(Self.guestTimeout)) s)"
        }
    }

    private func guestFileTail(_ path: String) -> String {
        guard let root = (host as? LinuxGraphicsHost)?.guestRootURL else { return "" }
        return Self.tail(of: BackupService.hostURL(root: root, guestPath: path), maxBytes: Self.maxLogBytes)
    }

    static func tail(of url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func directoryText(_ directory: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { fileText($0, title: $0.lastPathComponent) }.joined()
    }

    private func fileText(_ url: URL, title: String) -> String {
        let text = Self.tail(of: url, maxBytes: Self.maxLogBytes)
        return text.isEmpty ? "" : "===== \(title) =====\n\(text)\n\n"
    }

    private func eventsText() -> String {
        let lines = center.events.suffix(100).map { "\($0.date.formatted(.iso8601))  \($0.kind.rawValue)  \($0.detail)" }
        return lines.isEmpty ? "No problems recorded." : lines.joined(separator: "\n")
    }

    private func infoText(guestAnswers: Bool) async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let defaults = UserDefaults.standard
        var lines: [String] = []
        func line(_ key: String, _ value: String?) { lines.append("\(key): \(value ?? "unknown")") }
        line("App", "\(info["CFBundleDisplayName"] as? String ?? "LinPad") \(BackupService.appVersion) (\(BackupService.appBuild))")
        line("Bundled repair kit", RepairKit.bundled()?.manifest.version)
        if guestAnswers {
            line("Linux system (rootfs)", await guest("cat /usr/share/ish/rootfs-version 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines))
            line("Applied repair kit", await guest("cat \(RepairKit.installedVersionPath) 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines))
            line("Alpine", await guest("cat /etc/alpine-release 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines))
            line("Kernel", await guest("uname -a").trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            line("Linux", "not answering")
        }
        line("iPad model", "\(LinuxDeviceInfo.modelIdentifier) (\(defaults.string(forKey: LinuxDeviceInfo.hostModelKey) ?? "?"))")
        line("iPadOS", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        line("CPU engine", defaults.string(forKey: LinuxDeviceInfo.cpuEngineKey))
        if let fastMode = (host as? FastModeControlling)?.fastMode {
            line("Fast mode", String(describing: fastMode.status))
        }
        let memory = Self.memory()
        line("Physical memory", BackupService.bytes(Int64(ProcessInfo.processInfo.physicalMemory)))
        line("Available to LinPad now (os_proc_available_memory)", BackupService.bytes(Int64(memory.available)))
        line("LinPad's footprint now", memory.footprint.map { BackupService.bytes(Int64($0)) })
        line("LinPad's peak footprint", memory.peak.map { BackupService.bytes(Int64($0)) })
        line("Thermal state", "\(ProcessInfo.processInfo.thermalState.rawValue)")
        line("Low Power Mode", ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        line("Free storage", BackupService.freeSpace(at: documents).map(BackupService.bytes))
        line("Uptime of LinPad", String(format: "%.0f s", ProcessInfo.processInfo.systemUptime - center.launchUptime))
        line("Last backup", BackupService.shared(for: host).lastBackup?.formatted(.iso8601) ?? "never")
        return lines.joined(separator: "\n")
    }

    static func memory() -> (available: Int, footprint: UInt64?, peak: UInt64?) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let available = os_proc_available_memory()
        guard result == KERN_SUCCESS else { return (available, nil, nil) }
        return (available, info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }
}
