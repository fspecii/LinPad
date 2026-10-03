import SwiftUI
import UIKit
import WebKit

enum BrowserApp {
    static let defaultURL = "http://localhost:5173"

    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            // The Linux browser is the desktop's browser; this native WebKit view stays for
            // quickly previewing a page or local HTML file.
            id: AppID.browser, name: "Quick Preview", symbol: "eye", category: .internet,
            defaultSize: CGSize(width: 1024, height: 700)
        ) { context in
            AnyView(BrowserAppView(context: context))
        }
    }
}

enum BrowserURL {
    /// Turns what people type into a URL: "localhost:3000", ":5173", "5173", "example.com",
    /// full URLs, or free text (searched).
    static func normalize(_ raw: String) -> URL? {
        let input = raw.trimmedWhitespace
        guard !input.isEmpty else { return nil }

        if input.hasPrefix(":"), isPort(input.dropFirst()) {
            return URL(string: "http://localhost" + input)
        }
        if isPort(Substring(input)) {
            return URL(string: "http://localhost:" + input)
        }
        if input.contains("://") || input.hasPrefix("about:") || input.hasPrefix("data:") {
            return URL(string: input)
        }
        if input.contains(" ") || (!input.contains(".") && !input.contains(":") && input != "localhost") {
            var components = URLComponents(string: "https://duckduckgo.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: input)]
            return components?.url
        }
        let candidate = URL(string: "http://" + input)
        // Dev servers in the guest speak plain HTTP; public sites need HTTPS to pass ATS.
        if let host = candidate?.host, !isLocal(host), candidate?.port == nil {
            return URL(string: "https://" + input)
        }
        return candidate
    }

    private static func isPort(_ value: Substring) -> Bool {
        (2...5).contains(value.count) && value.allSatisfy(\.isNumber)
    }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
    }
}

// MARK: - Model

@MainActor
final class BrowserWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onFailure: ((Error) -> Void)?
    var onStart: (() -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onStart?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        onFailure?(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFailure?(error)
    }

    var navigationMenu: (() -> UIMenu)?

    /// Links get Open, Open in Default Browser and Copy Link above the page's navigation items.
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL else { return nil }
        let navigation = navigationMenu
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let link = UIMenu(options: .displayInline, children: [
                UIAction(title: "Open Link", image: UIImage.themed(systemName: "arrow.up.right.square")) { _ in
                    webView.load(URLRequest(url: url))
                },
                UIAction(title: "Open in Default Browser", image: UIImage.themed(systemName: "globe")) { _ in
                    UIApplication.shared.open(url)
                },
                UIAction(title: "Copy Link", image: UIImage.themed(systemName: "link")) { _ in
                    UIPasteboard.general.url = url
                },
            ])
            return UIMenu(children: [link] + (navigation.map { [$0()] } ?? []))
        }
    }

    /// target="_blank" links: there are no tabs, so open them in place.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

@MainActor
@Observable
final class BrowserModel {
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let window: any WindowHandle
    @ObservationIgnored private let delegate = BrowserWebDelegate()
    @ObservationIgnored private let pageMenu = BrowserPageMenu()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private let initialAddress: String

    var addressText: String
    private(set) var pageTitle = ""
    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    var errorMessage: String?

    init(context: AppLaunchContext) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        window = context.window
        initialAddress = context.arguments[AppArgument.url] ?? BrowserApp.defaultURL
        addressText = initialAddress
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.addInteraction(UIContextMenuInteraction(delegate: pageMenu))
        pageMenu.makeMenu = { [weak self] in self?.navigationMenu() ?? UIMenu() }
        delegate.navigationMenu = { [weak self] in self?.navigationMenu() ?? UIMenu() }
        delegate.onFailure = { [weak self] error in self?.handleFailure(error) }
        delegate.onStart = { [weak self] in self?.errorMessage = nil }
        observeWebView()
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        go(to: initialAddress)
    }

    func go(to input: String) {
        guard let url = BrowserURL.normalize(input) else {
            errorMessage = "“\(input)” isn't a valid address."
            return
        }
        errorMessage = nil
        addressText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Back, Forward, Reload, Open in Default Browser and Copy Link for the page itself.
    func navigationMenu() -> UIMenu {
        let page = webView.url
        return UIMenu(options: .displayInline, children: [
            UIAction(title: "Back", image: UIImage.themed(systemName: "chevron.left"),
                     attributes: webView.canGoBack ? [] : .disabled) { [weak self] _ in self?.goBack() },
            UIAction(title: "Forward", image: UIImage.themed(systemName: "chevron.right"),
                     attributes: webView.canGoForward ? [] : .disabled) { [weak self] _ in self?.goForward() },
            UIAction(title: "Reload", image: UIImage.themed(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.webView.reload()
            },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Open in Default Browser", image: UIImage.themed(systemName: "globe"),
                         attributes: page?.scheme?.hasPrefix("http") == true ? [] : .disabled) { _ in
                    if let page { UIApplication.shared.open(page) }
                },
                UIAction(title: "Copy Link", image: UIImage.themed(systemName: "link"), attributes: page == nil ? .disabled : []) { _ in
                    UIPasteboard.general.url = page
                },
            ]),
        ])
    }

    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else if webView.url == nil {
            go(to: addressText)
        } else {
            errorMessage = nil
            webView.reload()
        }
    }

    // MARK: Private

    private func observeWebView() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.updateTitle(webView.title ?? "") }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.currentURL = webView.url }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
        ]
    }

    private func updateTitle(_ title: String) {
        pageTitle = title
        window.setTitle(title.isEmpty ? (currentURL?.host ?? "Quick Preview") : title)
    }

    private func handleFailure(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads (a new navigation replaced this one) and policy interruptions
        // (downloads, custom schemes) are not failures the user needs to see.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == WKError.errorDomain && nsError.code == 102 { return }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? currentURL
        let target = failingURL?.absoluteString ?? "the page"
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotConnectToHost {
            errorMessage = "Couldn't connect to \(target). Is the dev server running? (e.g. `npx vite --host` in Terminal)"
        } else {
            errorMessage = "Couldn't load \(target): \(error.localizedDescription)"
        }
    }
}

/// The page's context menu (secondary click or long press on anything but a link, which
/// WebKit's own menu handles with the link items).
@MainActor
final class BrowserPageMenu: NSObject, UIContextMenuInteractionDelegate {
    var makeMenu: (() -> UIMenu)?

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let makeMenu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in makeMenu() }
    }
}

// MARK: - Views

struct BrowserAppView: View {
    @Environment(\.desktopTheme) private var theme
    @State private var model: BrowserModel
    @FocusState private var addressFocused: Bool

    private static let quickPorts = [5173, 3000, 8080]

    init(context: AppLaunchContext) {
        _model = State(initialValue: BrowserModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            progressBar
            if let message = model.errorMessage {
                InlineBanner(kind: .error, message: message, actionTitle: "Retry",
                             action: { model.go(to: model.addressText) },
                             onDismiss: { model.errorMessage = nil })
            }
            WebViewRepresentable(webView: model.webView)
                .background(Color.white)
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .animation(.easeOut(duration: 0.18), value: model.errorMessage)
        .task { model.startIfNeeded() }
        .onChange(of: model.currentURL) { _, url in
            if !addressFocused, let url { model.addressText = url.absoluteString }
        }
    }

    private var toolbar: some View {
        AppToolbar {
            ToolbarIconButton("chevron.left", help: "Back") { model.goBack() }
                .disabled(!model.canGoBack)
            ToolbarIconButton("chevron.right", help: "Forward") { model.goForward() }
                .disabled(!model.canGoForward)
            ToolbarIconButton(model.isLoading ? "xmark" : "arrow.clockwise",
                              help: model.isLoading ? "Stop" : "Reload") { model.reloadOrStop() }
            addressField
                .padding(.horizontal, 4)
            ForEach(Self.quickPorts, id: \.self) { port in
                quickPortButton(port)
            }
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: model.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            TextField("Enter address or localhost:port", text: $model.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    model.go(to: model.addressText)
                    addressFocused = false
                }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.windowBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(addressFocused ? theme.accent : theme.separator, lineWidth: addressFocused ? 1.5 : 1))
    }

    private func quickPortButton(_ port: Int) -> some View {
        let isCurrent = model.currentURL?.port == port && model.currentURL?.host == "localhost"
        return Button {
            model.go(to: "localhost:\(port)")
        } label: {
            Text(":\(port)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isCurrent ? Color.white : theme.primaryText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(isCurrent ? theme.accent : theme.primaryText.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help("Open localhost:\(port)")
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(theme.accent)
                .frame(width: proxy.size.width * model.progress)
                .opacity(model.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: model.progress)
        }
        .frame(height: 2)
    }
}

private struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

#Preview("Quick Preview") {
    BrowserAppView(context: AppsPreview.context([AppArgument.url: "https://example.com"]))
        .frame(width: 1024, height: 700)
}
