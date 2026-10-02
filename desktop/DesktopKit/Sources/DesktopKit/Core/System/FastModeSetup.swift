import Darwin
import SwiftUI
import UIKit

/// Optional host facts for the fast-mode setup checks.
@MainActor
public protocol FastModeDiagnosing: AnyObject {
    /// Whether the app's signature has get-task-allow (needed for any debugger to attach).
    var hasGetTaskAllow: Bool { get }
}

/// The apps fast mode depends on, and how LinPad talks to them.
enum FastModeHelpers {
    static let stikDebugScheme = URL(string: "stikdebug://")!
    static let stikDebugPage = URL(string: "https://stikdebug.xyz/")!
    static let stikDebugGuide = URL(string: "https://github.com/StikDebug/StikDebug-Guide")!
    static let localDevVPNScheme = URL(string: "localdevvpn://")!
    /// Connects the VPN, then comes back to LinPad through its `linpad://` scheme.
    static let localDevVPNConnect = URL(string: "localdevvpn://enable?scheme=linpad")!
    static let localDevVPNStore = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    /// Both schemes are in LSApplicationQueriesSchemes (app/Info.plist).
    static func isInstalled(_ scheme: URL) -> Bool {
        UIApplication.shared.canOpenURL(scheme)
    }

    /// LocalDevVPN's tunnel shows up as a utun interface on 10.7.0.x. A heuristic: other
    /// VPNs can use that range, and a custom LocalDevVPN address is not seen.
    static func localDevVPNLooksConnected() -> Bool {
        tunnelAddresses().contains { $0.hasPrefix("10.7.0.") }
    }

    static func tunnelAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

/// One line of the checklist.
struct FastModeCheck: Identifiable, Equatable {
    enum State: Equatable {
        case ok
        case missing
        /// Cannot be seen from LinPad (e.g. StikDebug's pairing file).
        case manual
        case info
    }

    let id: String
    let title: String
    let state: State
    let detail: String

    /// The checklist from what LinPad can observe, in setup order.
    static func evaluate(jitCompiledIn: Bool, isSimulator: Bool, hasGetTaskAllow: Bool?, stikDebugInstalled: Bool,
                         localDevVPNInstalled: Bool, vpnLooksConnected: Bool, status: FastModeModel.Status,
                         engine: LinuxSystemPreparation.CPUEngine?) -> [FastModeCheck] {
        var checks: [FastModeCheck] = []
        checks.append(FastModeCheck(id: "build", title: "This build includes the native JIT",
                                    state: jitCompiledIn ? .ok : .missing,
                                    detail: jitCompiledIn ? "Built with ISH_JIT_BUILD." : "Install a release build of LinPad; this one has no JIT."))
        if isSimulator {
            checks.append(FastModeCheck(id: "device", title: "Running on an iPad", state: .missing,
                                        detail: "The simulator has no StikDebug. Fast mode needs a real iPad."))
        }
        let taskAllow: State = hasGetTaskAllow.map { $0 ? .ok : .missing } ?? .info
        checks.append(FastModeCheck(id: "get-task-allow", title: "Signed so a debugger may attach (get-task-allow)", state: taskAllow,
                                    detail: taskAllow == .missing
                                        ? "Reinstall LinPad with SideStore, AltStore, iloader or Xcode: they sign with a development certificate that allows it."
                                        : "The installation allows StikDebug to attach."))
        checks.append(FastModeCheck(id: "stikdebug", title: "StikDebug installed", state: stikDebugInstalled ? .ok : .missing,
                                    detail: stikDebugInstalled ? "LinPad opens it at launch to enable the JIT."
                                        : "StikDebug is the on-device debugger that enables the JIT. Install it from stikdebug.xyz."))
        checks.append(FastModeCheck(id: "pairing", title: "StikDebug has a pairing file for this iPad", state: .manual,
                                    detail: "LinPad cannot see this. Make one on a computer (for example with iloader) and import it in StikDebug, then turn on Developer Mode."))
        checks.append(FastModeCheck(id: "localdevvpn", title: "LocalDevVPN installed", state: localDevVPNInstalled ? .ok : .missing,
                                    detail: localDevVPNInstalled ? "StikDebug reaches the iPad's debug service through it."
                                        : "Install LocalDevVPN from the App Store; StikDebug needs it."))
        checks.append(FastModeCheck(id: "vpn", title: "LocalDevVPN connected", state: vpnLooksConnected ? .ok : (localDevVPNInstalled ? .missing : .info),
                                    detail: vpnLooksConnected ? "A LocalDevVPN tunnel (10.7.0.x) is up."
                                        : "Connect it before testing; LinPad can open LocalDevVPN and come back."))
        let last: (State, String) = {
            switch (engine, status) {
            case (.nativeJIT?, _): return (.ok, "Linux runs on the native JIT.")
            case (_, .on(let newOnly)): return (.ok, newOnly ? "On for programs started since." : "On.")
            case (_, .failed(let message)): return (.missing, message)
            case (_, .enabling): return (.info, "Waiting for StikDebug…")
            default: return (.info, "Not tried at this launch.")
            }
        }()
        checks.append(FastModeCheck(id: "result", title: "Last handoff to StikDebug", state: last.0, detail: last.1))
        return checks
    }
}

/// Settings › Fast Mode › Set Up: the checklist, the buttons that fix each item, and a
/// test that runs the handoff and times the JIT.
struct FastModeSetupSheet: View {
    @Bindable var fastMode: FastModeModel
    @Environment(\.desktopController) private var controller
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var checks: [FastModeCheck] = []
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle
        case running(String)
        case finished(success: Bool, summary: String)
    }

    private var preparation: LinuxSystemPreparation? {
        (controller?.host as? LinuxSystemPreparing)?.preparation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Fast mode runs Linux programs as native ARM64 code, about 5x faster. iPadOS allows that only while a debugger is attached, so LinPad asks StikDebug to attach at launch. Work down the list; each step has a button.")
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(checks) { check in row(check) }
                    Divider()
                    testSection
                }
                .padding(24)
            }
            .navigationTitle("Set Up Fast Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Recheck", systemImage: "arrow.clockwise") { refresh() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 600)
        .onAppear(perform: refresh)
        // Back from StikDebug, LocalDevVPN or the App Store.
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onChange(of: fastMode.status) { _, _ in refresh() }
        .accessibilityIdentifier("desktop.fastModeSetup")
    }

    private func refresh() {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        checks = FastModeCheck.evaluate(
            jitCompiledIn: preparation?.jitCompiledIn ?? !(fastMode.unavailableReason?.contains("does not include") ?? false),
            isSimulator: simulator,
            hasGetTaskAllow: (controller?.host as? FastModeDiagnosing)?.hasGetTaskAllow,
            stikDebugInstalled: FastModeHelpers.isInstalled(FastModeHelpers.stikDebugScheme),
            localDevVPNInstalled: FastModeHelpers.isInstalled(FastModeHelpers.localDevVPNScheme),
            vpnLooksConnected: FastModeHelpers.localDevVPNLooksConnected(),
            status: fastMode.status, engine: preparation?.engine)
    }

    private func row(_ check: FastModeCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(check.state))
                .foregroundStyle(tint(check.state))
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(.callout.weight(.semibold))
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions(for: check)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fastModeSetup.\(check.id)")
    }

    @ViewBuilder
    private func actions(for check: FastModeCheck) -> some View {
        let buttons: [(String, URL)] = {
            switch check.id {
            case "stikdebug":
                return check.state == .ok ? [("Open StikDebug", FastModeHelpers.stikDebugScheme)]
                    : [("Get StikDebug", FastModeHelpers.stikDebugPage), ("Setup guide", FastModeHelpers.stikDebugGuide)]
            case "pairing":
                return [("Pairing guide", FastModeHelpers.stikDebugGuide)]
            case "localdevvpn" where check.state != .ok:
                return [("App Store", FastModeHelpers.localDevVPNStore)]
            case "vpn" where check.state != .ok && FastModeHelpers.isInstalled(FastModeHelpers.localDevVPNScheme):
                return [("Connect LocalDevVPN", FastModeHelpers.localDevVPNConnect)]
            default:
                return []
            }
        }()
        if !buttons.isEmpty {
            HStack {
                ForEach(buttons, id: \.0) { title, url in
                    Button(title) { UIApplication.shared.open(url) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test now").font(.headline)
            Text("Asks StikDebug for the JIT (StikDebug comes to the front and returns), then times a shell loop in Linux.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await runTest() }
                } label: {
                    Label("Test Fast Mode", systemImage: "bolt")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)
                .accessibilityIdentifier("fastModeSetup.test")
                if isTesting { ProgressView().controlSize(.small) }
            }
            switch testState {
            case .idle:
                EmptyView()
            case .running(let step):
                Text(step).font(.callout).foregroundStyle(.secondary)
            case .finished(let success, let summary):
                Label(summary, systemImage: success ? "checkmark.seal.fill" : "xmark.octagon")
                    .foregroundStyle(success ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fastModeSetup.testResult")
            }
        }
    }

    private var isTesting: Bool {
        if case .running = testState { return true }
        return false
    }

    private func runTest() async {
        let start = Date()
        if preparation?.engine != .nativeJIT {
            if case .on = fastMode.status {} else {
                guard fastMode.canRetry else {
                    testState = .finished(success: false, summary: fastMode.unavailableReason ?? fastMode.statusText)
                    return
                }
                testState = .running("Waiting for StikDebug…")
                fastMode.retry()
                // StikDebug is in front meanwhile; give up after two minutes.
                for _ in 0..<480 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if case .on = fastMode.status { break }
                    if case .failed = fastMode.status { break }
                }
            }
        }
        let handoff = Date().timeIntervalSince(start)
        let jitOn: Bool = {
            if preparation?.engine == .nativeJIT { return true }
            if case .on = fastMode.status { return true }
            return false
        }()
        guard jitOn else {
            testState = .finished(success: false, summary: "Fast mode did not come on: \(fastMode.statusText)")
            refresh()
            return
        }
        testState = .running("Timing a shell loop in Linux…")
        let loop = await benchmark()
        let handoffText = handoff < 0.5 ? "already on" : String(format: "handoff %.1f s", handoff)
        testState = .finished(success: true, summary: "JIT: native ✓ (\(handoffText)). " + (loop.map {
            String(format: "200,000-iteration shell loop: %.2f s (Compatibility mode takes about 5x longer).", $0)
        } ?? "The timing run did not finish."))
        refresh()
    }

    /// Seconds for a busy shell loop in a new process (new processes use the JIT).
    private func benchmark() async -> Double? {
        guard let host = controller?.host else { return nil }
        let begin = Date()
        let result = await host.run("i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done; echo $i", cwd: nil, stdin: nil)
        guard result.succeeded, result.stdout.contains("200000") else { return nil }
        return Date().timeIntervalSince(begin)
    }

    private func symbol(_ state: FastModeCheck.State) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .missing: "xmark.circle.fill"
        case .manual: "hand.point.right.fill"
        case .info: "info.circle.fill"
        }
    }

    private func tint(_ state: FastModeCheck.State) -> Color {
        switch state {
        case .ok: .green
        case .missing: .orange
        case .manual, .info: .secondary
        }
    }
}
