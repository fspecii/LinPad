import SwiftUI
import UIKit

enum TaskManagerApp {
    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: AppID.taskManager, name: "Task Manager", symbol: "gauge.with.dots.needle.33percent",
            category: .system, defaultSize: CGSize(width: 780, height: 540)
        ) { context in
            AnyView(TaskManagerAppView(context: context))
        }
    }
}

// MARK: - Model

enum ProcessSortKey: String {
    case pid = "PID", name = "Name", user = "User", memory = "Memory"
}

@MainActor
@Observable
final class TaskManagerModel {
    private static let loadMarker = "__DK_LOADAVG__"
    private static let memoryMarker = "__DK_MEMINFO__"
    private static let psColumns = "pid,ppid,user,vsz,stat,comm,args"
    /// One round trip per refresh; busybox builds without `-o` fall back to plain `ps`.
    private static let snapshotCommand = """
        ps -o \(psColumns) 2>/dev/null || ps
        echo \(loadMarker)
        cat /proc/loadavg 2>/dev/null
        echo \(memoryMarker)
        cat /proc/meminfo 2>/dev/null
        """
    static let refreshInterval: Duration = .seconds(2)

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private let window: any WindowHandle

    private(set) var processes: [ProcessRow] = []
    private(set) var load: SystemLoad?
    private(set) var memory: MemoryInfo?
    private(set) var hasLoaded = false
    var errorMessage: String?
    var searchText = ""
    var sortKey: ProcessSortKey = .memory
    var ascending = false
    var selection: Int?

    init(context: AppLaunchContext) {
        host = context.host
        window = context.window
    }

    var selectedProcess: ProcessRow? {
        selection.flatMap { pid in processes.first { $0.pid == pid } }
    }

    var visibleProcesses: [ProcessRow] {
        let query = searchText.trimmedWhitespace.lowercased()
        let filtered = query.isEmpty ? processes : processes.filter {
            $0.name.lowercased().contains(query) || $0.command.lowercased().contains(query)
                || String($0.pid) == query || $0.user.lowercased() == query
        }
        return filtered.sorted { lhs, rhs in
            let ordered: Bool
            switch sortKey {
            case .pid:
                ordered = lhs.pid < rhs.pid
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                ordered = comparison == .orderedSame ? lhs.pid < rhs.pid : comparison == .orderedAscending
            case .user:
                ordered = lhs.user == rhs.user ? lhs.pid < rhs.pid : lhs.user < rhs.user
            case .memory:
                let left = lhs.memoryKB ?? -1
                let right = rhs.memoryKB ?? -1
                ordered = left == right ? lhs.pid < rhs.pid : left < right
            }
            return ascending ? ordered : !ordered
        }
    }

    func setSort(_ key: ProcessSortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = key == .name || key == .user || key == .pid
        }
    }

    /// Runs until the surrounding `.task` is cancelled, i.e. while the view is on screen.
    func poll() async {
        window.setTitle("Task Manager")
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: Self.refreshInterval)
            } catch {
                return
            }
        }
    }

    func refresh() async {
        let result = await host.run(Self.snapshotCommand, cwd: nil, stdin: nil)
        guard !Task.isCancelled else { return }
        let psPart: String
        var loadPart = ""
        var memoryPart = ""
        if let loadRange = result.stdout.range(of: Self.loadMarker) {
            psPart = String(result.stdout[..<loadRange.lowerBound])
            let rest = result.stdout[loadRange.upperBound...]
            if let memoryRange = rest.range(of: Self.memoryMarker) {
                loadPart = String(rest[..<memoryRange.lowerBound])
                memoryPart = String(rest[memoryRange.upperBound...])
            } else {
                loadPart = String(rest)
            }
        } else {
            psPart = result.stdout
        }

        let parsed = ProcessListParser.parse(psPart).filter { !isSnapshotProcess($0) }
        if parsed.isEmpty {
            errorMessage = result.stderr.trimmedWhitespace.isEmpty
                ? "Couldn't read the process list from `ps`."
                : result.failureDescription
        } else {
            errorMessage = nil
            processes = parsed
        }
        load = ProcFSParser.loadAverage(loadPart)
        memory = ProcFSParser.memory(memoryPart)
        hasLoaded = true
        if let selection, !processes.contains(where: { $0.pid == selection }) {
            self.selection = nil
        }
    }

    func send(_ signal: ProcessSignal, to process: ProcessRow) {
        Task {
            let result = await host.run("kill -\(signal.name) \(process.pid)", cwd: nil, stdin: nil)
            if !result.succeeded {
                errorMessage = "Couldn't stop \(process.name) (\(process.pid)): \(result.failureDescription)"
            }
            await refresh()
        }
    }

    private func isSnapshotProcess(_ process: ProcessRow) -> Bool {
        process.command.contains(Self.loadMarker) || process.command.hasPrefix("ps -o \(Self.psColumns)")
            || (process.name == "ps" && process.command == "ps")
    }
}

enum ProcessSignal {
    case terminate, kill

    var name: String { self == .terminate ? "TERM" : "KILL" }
    var title: String { self == .terminate ? "End Process" : "Force Kill" }
}

// MARK: - Views

struct TaskManagerAppView: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopWindowIsVisible) private var isWindowVisible
    @State private var model: TaskManagerModel
    @State private var pendingSignal: (process: ProcessRow, signal: ProcessSignal)?

    init(context: AppLaunchContext) {
        _model = State(initialValue: TaskManagerModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            AppToolbar {
                AppSearchField(prompt: "Filter processes", text: $model.searchText)
                    .frame(maxWidth: 260)
                Spacer(minLength: 8)
                ToolbarTextButton(title: "End Process", symbol: "stop.circle") {
                    if let process = model.selectedProcess { pendingSignal = (process, .terminate) }
                }
                .disabled(model.selectedProcess == nil)
                ToolbarTextButton(title: "Force Kill", symbol: "xmark.octagon") {
                    if let process = model.selectedProcess { pendingSignal = (process, .kill) }
                }
                .disabled(model.selectedProcess == nil)
                ToolbarIconButton("arrow.clockwise", help: "Refresh Now") {
                    Task { await model.refresh() }
                }
            }
            if let message = model.errorMessage {
                InlineBanner(kind: .error, message: message, onDismiss: { model.errorMessage = nil })
            }
            processTable
            AppStatusBar {
                Text("\(model.processes.count) processes")
                if let tasks = model.load?.tasks {
                    Text("Running/total: \(tasks)")
                }
                Spacer(minLength: 0)
                Text("Refreshes every 2 s")
            }
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .task(id: isWindowVisible) {
            if isWindowVisible { await model.poll() }
        }
        .alert(signalTitle, isPresented: isSignalPresented, presenting: pendingSignal) { pending in
            Button(pending.signal.title, role: .destructive) {
                model.send(pending.signal, to: pending.process)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.signal == .terminate
                 ? "Sends SIGTERM to “\(pending.process.name)” (PID \(pending.process.pid)), asking it to quit."
                 : "Sends SIGKILL to “\(pending.process.name)” (PID \(pending.process.pid)). Unsaved work will be lost.")
        }
    }

    // MARK: Summary

    private var summary: some View {
        HStack(spacing: 12) {
            summaryCard(title: "Load average", symbol: "cpu") {
                if let load = model.load {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        loadValue(load.one, label: "1m")
                        loadValue(load.five, label: "5m")
                        loadValue(load.fifteen, label: "15m")
                    }
                } else {
                    placeholder
                }
            }
            summaryCard(title: "Memory", symbol: "memorychip") {
                if let memory = model.memory {
                    VStack(alignment: .leading, spacing: 5) {
                        UsageBar(fraction: memory.usedFraction)
                        Text("\(ByteFormat.string(kilobytes: memory.usedKB)) of \(ByteFormat.string(kilobytes: memory.totalKB)) used")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    placeholder
                }
            }
        }
        .padding(12)
        .background(theme.panelBackground)
    }

    private var placeholder: some View {
        Text(model.hasLoaded ? "Unavailable" : "Loading…")
            .font(.callout)
            .foregroundStyle(theme.secondaryText)
    }

    private func summaryCard<Content: View>(title: String, symbol: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .stroke(theme.separator, lineWidth: 1))
    }

    private func loadValue(_ value: Double, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: Table

    private var processTable: some View {
        let rows = model.visibleProcesses
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                header(.pid, alignment: .trailing).frame(width: 56)
                header(.name).frame(width: 140)
                header(.user).frame(width: 70)
                header(.memory, alignment: .trailing).frame(width: 80)
                Text("State")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 44, alignment: .leading)
                Text("Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(theme.titleBarInactive)
            .overlay(alignment: .bottom) { ThemedSeparator() }

            if rows.isEmpty {
                if model.hasLoaded {
                    AppEmptyState(symbol: "magnifyingglass", title: "No matching processes")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, process in
                            row(process, striped: index.isMultiple(of: 2))
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func header(_ key: ProcessSortKey, alignment: Alignment = .leading) -> some View {
        SortableHeader(title: key.rawValue, isActive: model.sortKey == key, ascending: model.ascending,
                       alignment: alignment) {
            model.setSort(key)
        }
    }

    private func row(_ process: ProcessRow, striped: Bool) -> some View {
        let isSelected = model.selection == process.pid
        return HStack(spacing: 10) {
            Text(String(process.pid))
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(theme.secondaryText)
            Text(process.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            Text(process.user)
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(theme.secondaryText)
            Text(process.memoryKB.map { ByteFormat.string(kilobytes: $0) } ?? "—")
                .frame(width: 80, alignment: .trailing)
            Text(process.state)
                .frame(width: 44, alignment: .leading)
                .foregroundStyle(process.state.hasPrefix("R") ? Color.green : theme.secondaryText)
            Text(process.command)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13).monospacedDigit())
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(isSelected ? theme.accent.opacity(0.28) : (striped ? theme.primaryText.opacity(0.025) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = process.pid }
        .hoverEffect(.highlight)
        .contextMenu {
            Button { pendingSignal = (process, .terminate) } label: {
                Label("End Process (SIGTERM)", systemImage: "stop.circle")
            }
            Button(role: .destructive) { pendingSignal = (process, .kill) } label: {
                Label("Force Kill (SIGKILL)", systemImage: "xmark.octagon")
            }
            Divider()
            Button { UIPasteboard.general.string = String(process.pid) } label: {
                Label("Copy PID", systemImage: "number")
            }
            Button { UIPasteboard.general.string = process.command } label: {
                Label("Copy Command", systemImage: "doc.on.doc")
            }
        }
    }

    private var isSignalPresented: Binding<Bool> {
        Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } })
    }

    private var signalTitle: String {
        guard let pendingSignal else { return "" }
        return "\(pendingSignal.signal.title): \(pendingSignal.process.name)?"
    }
}

private struct UsageBar: View {
    @Environment(\.desktopTheme) private var theme
    let fraction: Double

    private var tint: Color {
        switch fraction {
        case ..<0.7: return theme.accent
        case ..<0.9: return Color.orange
        default: return Color.red
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.primaryText.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

#Preview("Task Manager") {
    TaskManagerAppView(context: AppsPreview.context())
        .frame(width: 780, height: 540)
}
