import SwiftUI

/// What the emulator's out-of-memory monitor reports in /proc/ish/memory (kernel/oom.c):
/// LinPad's footprint against the allowance iPadOS gives it, the policy, recent closes and
/// the guest processes using the most memory.
struct GuestMemoryStatus: Equatable {
    struct Process: Equatable, Identifiable {
        var pid: Int
        var megabytes: Int
        var adjustment: Int
        var isProtected: Bool
        var name: String
        var id: Int { pid }
    }

    struct Close: Equatable, Identifiable {
        var date: Date
        var pid: Int
        var freedMB: Int
        var footprintMB: Int
        var allowanceMB: Int
        var name: String
        var id: String { "\(pid)-\(date.timeIntervalSince1970)" }
    }

    var footprintMB = 0
    /// 0 when the host sets no limit (the simulator, a Mac).
    var allowanceMB = 0
    var softMB = 0
    var hardMB = 0
    var killerEnabled = true
    var closes: [Close] = []
    var processes: [Process] = []

    init() {}

    init(parsing text: String) {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5).map(String.init)
            guard let key = fields.first, fields.count >= 2 else { continue }
            let number = Int(fields[1]) ?? 0
            switch key {
            case "footprint_mb": footprintMB = number
            case "allowance_mb": allowanceMB = number
            case "soft_mb": softMB = number
            case "hard_mb": hardMB = number
            case "oom_enabled": killerEnabled = number != 0
            case "kill" where fields.count == 6:
                // kill TIME PID FREED_MB FOOTPRINT_MB ALLOWANCE_MB NAME...
                let rest = fields[5].split(separator: " ", maxSplits: 1).map(String.init)
                guard rest.count == 2 else { continue }
                closes.append(Close(date: Date(timeIntervalSince1970: TimeInterval(number)),
                                    pid: Int(fields[2]) ?? 0, freedMB: Int(fields[3]) ?? 0,
                                    footprintMB: Int(fields[4]) ?? 0, allowanceMB: Int(rest[0]) ?? 0,
                                    name: rest[1]))
            case "proc" where fields.count == 6:
                // proc PID MB ADJ PROTECTED NAME...
                processes.append(Process(pid: number, megabytes: Int(fields[2]) ?? 0,
                                         adjustment: Int(fields[3]) ?? 0, isProtected: fields[4] == "1",
                                         name: fields[5]))
            default: continue
            }
        }
    }

    var fraction: Double {
        allowanceMB > 0 ? min(1, Double(footprintMB) / Double(allowanceMB)) : 0
    }
}

enum MemorySettings {
    /// Bool, default true. Read by the app before boot (ISH_OOM) and applied at run time
    /// through /proc/ish/oom.
    static let closeAppsKey = "memory.closeAppsOnLowMemory"
    /// Comma-separated process names the monitor never closes (ISH_OOM_PROTECT).
    static let protectKey = "memory.protectedApps"
    static let statusPath = "/proc/ish/memory"
    /// Posted by the app (on the main queue) when the emulator's out-of-memory monitor
    /// closes a guest process; userInfo "app" and "message" (kernel/oom.h oom_kill_hook).
    static let appClosedNotification = Notification.Name("LinPadGuestAppClosedForMemory")
    static let policyPath = "/proc/ish/oom"

    static func policy(enabled: Bool) -> String { "enabled \(enabled ? 1 : 0)\n" }

    /// One line, names separated by commas, empty names dropped.
    static func policy(protecting names: String) -> String {
        let list = names.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return "protect \(list.joined(separator: ","))\n"
    }

    static func megabytes(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}

/// Settings › Performance › Memory.
struct MemorySettingsSection: View {
    let host: any LinuxHost
    @Environment(\.desktopTheme) private var theme
    @AppStorage(MemorySettings.closeAppsKey) private var closesApps = true
    @AppStorage(MemorySettings.protectKey) private var protectedApps = ""
    @State private var status = GuestMemoryStatus()
    @State private var protectDraft = ""
    @State private var loaded = false

    var body: some View {
        SettingsSection(title: "Memory", symbol: "memorychip") {
            usage
            SettingsRow(title: "Close apps when memory runs out") {
                Toggle("Close apps when memory runs out", isOn: $closesApps)
                    .labelsHidden()
                    .tint(theme.accent)
                    .accessibilityIdentifier("settings.memory.closeApps")
            }
            Text("Like a Linux out-of-memory killer: when LinPad nears the memory iPadOS allows it, the app using the most memory is closed (a Firefox tab before Firefox itself) and a notification says which. Off, iPadOS closes all of LinPad instead.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SettingsRow(title: "Never close") {
                TextField("process names, comma-separated", text: $protectDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 260)
                    .onSubmit { saveProtectList() }
                    .accessibilityIdentifier("settings.memory.protect")
            }
            if !status.processes.isEmpty { processList }
            if !status.closes.isEmpty { closeList }
        }
        .task {
            protectDraft = protectedApps
            loaded = true
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: closesApps) { _, on in
            guard loaded else { return }
            Task { await writePolicy(MemorySettings.policy(enabled: on)) }
        }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 4) {
            if status.allowanceMB > 0 {
                ProgressView(value: status.fraction)
                    .tint(status.footprintMB >= status.allowanceMB - status.hardMB ? .red :
                          status.footprintMB >= status.allowanceMB - status.softMB ? .orange : theme.accent)
                    .accessibilityIdentifier("settings.memory.usage")
                Text("LinPad uses \(MemorySettings.megabytes(status.footprintMB)) of the \(MemorySettings.megabytes(status.allowanceMB)) iPadOS allows it.")
                    .font(.callout)
            } else {
                Text("LinPad uses \(MemorySettings.megabytes(status.footprintMB)). This device sets no per-app limit.")
                    .font(.callout)
            }
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Using the most memory").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
            ForEach(status.processes.prefix(8)) { process in
                HStack {
                    Text(process.name).font(.callout).lineLimit(1)
                    if process.isProtected {
                        Text("never closed").font(.caption2).foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    Text(MemorySettings.megabytes(process.megabytes)).font(.callout.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("settings.memory.processes")
    }

    private var closeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recently closed to free memory").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
            ForEach(status.closes.reversed()) { close in
                HStack {
                    Text(close.name).font(.callout).lineLimit(1)
                    Spacer()
                    Text(close.date, style: .time).font(.caption).foregroundStyle(theme.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("settings.memory.closes")
    }

    private func refresh() async {
        let result = await host.run("cat \(MemorySettings.statusPath)")
        guard result.succeeded else { return }
        status = GuestMemoryStatus(parsing: result.stdout)
    }

    private func saveProtectList() {
        protectedApps = protectDraft
        Task { await writePolicy(MemorySettings.policy(protecting: protectDraft)) }
    }

    private func writePolicy(_ text: String) async {
        try? await host.writeFile(MemorySettings.policyPath, data: Data(text.utf8))
        await refresh()
    }
}
