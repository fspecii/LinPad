import SwiftUI

/// Links the app was opened with, waiting for the desktop to ask about them. The host's
/// scene delegate hands every URL here; links that arrive before the desktop exists wait.
@Observable @MainActor
public final class LinPadLinkInbox {
    public static let shared = LinPadLinkInbox()

    struct Pending: Identifiable {
        let id = UUID()
        let link: LinPadLink
    }

    var pending: Pending?

    /// True if the URL is a LinPad link (valid or not); the desktop shows what it does.
    @discardableResult
    public func receive(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == LinPadLink.scheme else { return false }
        guard let link = LinPadLink.parse(url) else {
            rejected = url
            return true
        }
        if link != .open { pending = Pending(link: link) }
        return true
    }

    /// The last link that could not be read, for a toast.
    var rejected: URL?
}

extension View {
    /// Asks about links handed to `LinPadLinkInbox` (see the host's scene delegate).
    func linPadLinks(controller: DesktopController) -> some View {
        modifier(LinPadLinkPresenter(controller: controller))
    }
}

private struct LinPadLinkPresenter: ViewModifier {
    let controller: DesktopController
    @Bindable private var inbox = LinPadLinkInbox.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $inbox.pending) { pending in
                LinkConfirmationSheet(link: pending.link, controller: controller)
            }
            .onChange(of: inbox.rejected) { _, url in
                guard url != nil else { return }
                controller.notify("That LinPad link is damaged or not supported by this version.")
                inbox.rejected = nil
            }
    }
}

/// What a link would do, and one button to do it.
struct LinkConfirmationSheet: View {
    let link: LinPadLink
    let controller: DesktopController
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: symbol)
                    .font(.title3.weight(.semibold))
                Text(explanation)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
                if case .importTheme(_, let toml) = link,
                   let theme = ColorsToml.read(toml, id: ColorsToml.id(forName: "preview"), name: "Preview") {
                    ThemePreviewCard(theme: theme, fallback: nil, showsNotification: false)
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Task { await perform() }
                    } label: {
                        if isWorking { ProgressView().controlSize(.small) } else { Text(actionTitle) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
                    .accessibilityIdentifier("link.confirm")
                }
            }
            .padding(24)
            .navigationTitle("Open LinPad Link")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(minWidth: 420, minHeight: 320)
        .accessibilityIdentifier("desktop.linkConfirmation")
        .task {
            let catalog = AppCatalogModel.shared(for: controller.host)
            if case .installApp = link, !catalog.hasLoaded { await catalog.load() }
        }
    }

    private var title: String {
        switch link {
        case .installTheme: "Install a colour theme"
        case .importTheme(let name, _): "Add the theme “\(name)”"
        case .applyLook(let look): "Apply the look “\(look.name)”"
        case .installApp(let id): "Install \(pack(id)?.name ?? id)"
        case .open: "Open LinPad"
        }
    }

    private var symbol: String {
        switch link {
        case .installTheme, .importTheme: "paintpalette"
        case .applyLook: "sparkles"
        case .installApp: "shippingbox"
        case .open: "arrow.up.forward.app"
        }
    }

    private var explanation: String {
        switch link {
        case .installTheme:
            "LinPad will download this git repository into ~/.config/linpad/colors with ish-colors and add it to Themes. Only install themes from people you trust."
        case .importTheme:
            "The link carries the theme's colours (an Omarchy-compatible colors.toml). It is saved as one of your themes and applied."
        case .applyLook(let look):
            "Style: \(look.style.displayName). Colour theme: \(lookThemeName(look)). Your current style, colours and window styling are replaced; save them as a Look first if you want to keep them."
        case .installApp(let id):
            pack(id).map { "\($0.description) About \($0.sizeText) is downloaded with apk on this iPad." }
                ?? "The app is installed from LinPad's optional-apps catalog (Settings › Apps)."
        case .open:
            ""
        }
    }

    private var detail: String? {
        switch link {
        case .installTheme(let git): git
        default: nil
        }
    }

    private var actionTitle: String {
        switch link {
        case .installTheme, .installApp: "Install"
        case .importTheme: "Add & Apply"
        case .applyLook: "Apply Look"
        case .open: "OK"
        }
    }

    private func pack(_ id: String) -> CatalogPack? {
        AppCatalogModel.shared(for: controller.host).packs.first { $0.id == id }
    }

    private func lookThemeName(_ look: DesktopLook) -> String {
        guard !look.colorThemeID.isEmpty else { return "the style's own" }
        if let theme = controller.colorThemes.theme(look.colorThemeID) { return theme.name }
        return "\(look.colorThemeID) (not installed here: the style's colours are used)"
    }

    private func perform() async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        if let message = await LinPadLinkActions.perform(link, controller: controller) {
            failure = message
        } else {
            dismiss()
        }
    }
}

/// Doing what a confirmed link asks; nil on success, else what went wrong.
@MainActor
enum LinPadLinkActions {
    static func perform(_ link: LinPadLink, controller: DesktopController) async -> String? {
        let host = controller.host
        switch link {
        case .open:
            return nil
        case .installTheme(let git):
            let before = Set(controller.colorThemes.themes.map(\.id))
            if let error = await controller.colorThemes.install(url: git, host: host) { return error }
            if let added = controller.colorThemes.themes.first(where: { !before.contains($0.id) }) {
                controller.applyColorTheme(added.id)
                controller.notify("Installed and applied \(added.name).")
            } else {
                controller.notify("Theme installed. Find it in Themes › Gallery.")
            }
            return nil
        case .importTheme(let name, let toml):
            guard let theme = ColorsToml.read(toml, id: ColorsToml.id(forName: name), name: name) else {
                return "The link's colours could not be read."
            }
            do {
                try await ThemeFiles.save(theme, host: host)
            } catch {
                return error.localizedDescription
            }
            controller.colorThemes.upsertLocal(theme)
            controller.applyColorTheme(theme.id)
            controller.notify("Added and applied \(theme.name).")
            return nil
        case .applyLook(var look):
            if controller.colorThemes.theme(look.colorThemeID) == nil { look.colorThemeID = "" }
            var looks = DesktopLook.loadUserLooks()
            looks.removeAll { $0.id == look.id }
            looks.append(look)
            DesktopLook.saveUserLooks(looks)
            controller.applyLook(look)
            return nil
        case .installApp(let id):
            let catalog = AppCatalogModel.shared(for: host)
            if !catalog.hasLoaded { await catalog.load() }
            guard let pack = catalog.packs.first(where: { $0.id == id }) else {
                return catalog.unavailableReason ?? "This Linux system has no app called “\(id)”. Update Linux, or check the link."
            }
            guard !pack.isInstalled else {
                controller.notify("\(pack.name) is already installed.")
                return nil
            }
            catalog.install([id])
            controller.open(appID: AppID.settings, arguments: [SettingsApp.pageArgument: SettingsApp.appsPage])
            controller.notify("Installing \(pack.name)… Settings › Apps shows the progress.")
            return nil
        }
    }
}
