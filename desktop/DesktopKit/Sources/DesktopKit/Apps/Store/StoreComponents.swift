import SwiftUI

// Building blocks of LinPad Store, shared by its pages and by onboarding's Apps step.
// Colours, radii and buttons come from the desktop theme and style, so the Store matches
// every desktop style (including the era skins' buttons via ToolbarTextButton).

/// The app's icon: the icon pack's (as the launcher draws it), else AppStream's, else a
/// category glyph on an accent tile.
struct StoreAppIcon: View {
    let app: StoreApp
    let size: CGFloat
    var mediaBase: String?
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopIcons) private var icons

    var body: some View {
        Group {
            if let packIcon = icons?.icon(app.iconNames ?? []), !packIcon.isSymbolic {
                Image(uiImage: packIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let url = remoteURL {
                StoreRemoteImage(url: url) { glyph }
            } else {
                glyph
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var remoteURL: URL? {
        guard let path = app.icon, !path.isEmpty else { return nil }
        if path.hasPrefix("https://") { return URL(string: path) }
        guard let mediaBase else { return nil }
        return URL(string: mediaBase + "/" + path)
    }

    private var glyph: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LinearGradient(colors: [theme.accent, theme.accent.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: app.categorySymbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(theme.accent.readableLabel)
            }
    }
}

/// "Runs on LinPad" status.
struct StoreCompatBadge: View {
    let compatibility: StoreCompatibility
    var compact = false
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: compatibility.symbol).font(.system(size: compact ? 10 : 11, weight: .semibold))
            Text(compact ? compatibility.title : "Runs on LinPad: \(compatibility.title)")
                .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Runs on LinPad: \(compatibility.title)")
    }

    private var tint: Color {
        switch compatibility {
        case .works: Color(red: 0.2, green: 0.72, blue: 0.42)
        case .experimental: Color(red: 0.95, green: 0.6, blue: 0.15)
        case .broken: theme.urgent
        case .untested: theme.secondaryText
        }
    }
}

/// Install / Open / Update / Remove, with the job's progress in place of the button while
/// it runs. `prominent` is the large button of the detail page.
struct StoreActionButton: View {
    let app: StoreApp
    let model: StoreModel
    var prominent = false
    var onOpen: (StoreApp) -> Void = { _ in }
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        if let job = model.job(for: app.id) {
            StoreJobProgress(job: job, model: model, compact: !prominent)
        } else if model.isInstalled(app) {
            HStack(spacing: 6) {
                if model.update(for: app) != nil {
                    ToolbarTextButton(title: "Update", symbol: prominent ? "arrow.triangle.2.circlepath" : nil, prominent: true) {
                        model.update([app.id])
                    }
                    .disabled(model.isOffline)
                    .accessibilityIdentifier("store.update.\(app.id)")
                }
                ToolbarTextButton(title: app.isCommandLine ? "Terminal" : "Open", symbol: prominent ? "arrow.up.forward.app" : nil,
                                  prominent: model.update(for: app) == nil) { onOpen(app) }
                    .accessibilityIdentifier("store.open.\(app.id)")
            }
        } else {
            ToolbarTextButton(title: model.state == nil ? "Get" : "Install", symbol: prominent ? "arrow.down.circle" : nil, prominent: true) {
                model.install([app.id])
            }
            .disabled(model.isOffline || model.state == nil)
            .accessibilityIdentifier("store.install.\(app.id)")
        }
    }
}

/// A job's state: a progress ring (compact) or a bar with its status and Cancel.
struct StoreJobProgress: View {
    let job: StoreJob
    let model: StoreModel
    var compact = true
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        if compact {
            HStack(spacing: 6) {
                ring.frame(width: 22, height: 22)
                if job.phase.isCancellable && !job.cancelRequested {
                    Button { model.cancel(job.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(theme.primaryText.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier("store.cancel.\(job.appIDs.first ?? "")")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(job.statusText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(job.statusText)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if job.phase.isCancellable && !job.cancelRequested {
                        ToolbarTextButton(title: "Cancel") { model.cancel(job.id) }
                            .accessibilityIdentifier("store.cancel.\(job.appIDs.first ?? "")")
                    }
                }
                StoreProgressBar(fraction: job.fraction)
                    .frame(height: 6)
                if !job.message.isEmpty, job.message != job.statusText {
                    Text(job.message).font(.system(size: 11)).foregroundStyle(theme.secondaryText).lineLimit(1)
                }
            }
            .frame(minWidth: 220, maxWidth: 320)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("store.progress.\(job.appIDs.first ?? "all")")
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(theme.primaryText.opacity(0.12), lineWidth: 3)
            if let fraction = job.fraction {
                Circle().trim(from: 0, to: fraction)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: fraction)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

/// A determinate bar, or an indeterminate sweeping one when `fraction` is nil.
struct StoreProgressBar: View {
    let fraction: Double?
    @Environment(\.desktopTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.primaryText.opacity(0.12))
                if let fraction {
                    Capsule().fill(theme.accent)
                        .frame(width: max(6, proxy.size.width * fraction))
                        .animation(.easeOut(duration: 0.3), value: fraction)
                } else {
                    Capsule().fill(theme.accent.opacity(0.85))
                        .frame(width: proxy.size.width * 0.3)
                        .offset(x: sweep ? proxy.size.width * 0.7 : 0)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
        }
        .accessibilityElement()
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

/// An app as a tile in a horizontal collection row or a grid.
struct StoreAppCard: View {
    let app: StoreApp
    let model: StoreModel
    var onSelect: (StoreApp) -> Void
    var onOpen: (StoreApp) -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { onSelect(app) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    StoreAppIcon(app: app, size: 56, mediaBase: model.index?.mediaBase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Text(app.summary ?? app.category)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("store.card.\(app.id)")
            HStack(spacing: 6) {
                if app.compatibility != .untested { StoreCompatBadge(compatibility: app.compatibility, compact: true) }
                else if let mb = app.estimatedMB {
                    Text(StoreFormat.megabytes(mb)).font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 4)
                StoreActionButton(app: app, model: model, onOpen: onOpen)
            }
        }
        .padding(12)
        .frame(width: 196)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).fill(theme.titleBarInactive))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).stroke(theme.separator.opacity(0.7), lineWidth: 1))
        .hoverEffect(.lift)
    }
}

/// An app as a row in search results, Installed and Updates.
struct StoreAppRow<Trailing: View>: View {
    let app: StoreApp
    let model: StoreModel
    var detail: String?
    var onSelect: (StoreApp) -> Void
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Button { onSelect(app) } label: {
                HStack(spacing: 12) {
                    StoreAppIcon(app: app, size: 44, mediaBase: model.index?.mediaBase)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.primaryText).lineLimit(1)
                            if app.compatibility != .untested { StoreCompatBadge(compatibility: app.compatibility, compact: true) }
                        }
                        Text(detail ?? app.summary ?? app.category)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.row.\(app.id)")
    }
}

struct StoreSectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 19, weight: .bold)).foregroundStyle(theme.primaryText)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .hoverEffect(.highlight)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Horizontally scrolling screenshots; tapping one shows it large.
struct StoreScreenshotStrip: View {
    let shots: [StoreScreenshot]
    let mediaBase: String
    var height: CGFloat = 240
    var onSelect: (Int) -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(Array(shots.enumerated()), id: \.offset) { index, shot in
                    Button { onSelect(index) } label: {
                        StoreRemoteImage(url: url(shot.url), contentMode: .fill) { offlinePlaceholder }
                            .frame(width: height * shot.aspectRatio, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.separator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shot.caption ?? "Screenshot \(index + 1)")
                    .accessibilityIdentifier("store.screenshot.\(index)")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: height)
    }

    private func url(_ path: String) -> URL? {
        path.hasPrefix("https://") ? URL(string: path) : URL(string: mediaBase + "/" + path)
    }

    private var offlinePlaceholder: some View {
        ZStack {
            theme.titleBarInactive
            VStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 26, weight: .light))
                Text("Screenshot unavailable offline").font(.system(size: 11))
            }
            .foregroundStyle(theme.secondaryText)
        }
    }
}

/// A screenshot at full size over a scrim, swipeable, closed by tap or Escape.
struct StoreScreenshotViewer: View {
    let shots: [StoreScreenshot]
    let mediaBase: String
    @Binding var selection: Int?
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        if let index = selection, shots.indices.contains(index) {
            ZStack {
                Color.black.opacity(0.82).ignoresSafeArea()
                    .onTapGesture { selection = nil }
                TabView(selection: Binding(get: { index }, set: { selection = $0 })) {
                    ForEach(Array(shots.enumerated()), id: \.offset) { i, shot in
                        VStack(spacing: 10) {
                            StoreRemoteImage(url: url(shot.full ?? shot.url)) { ProgressView() }
                                .padding(.horizontal, 40)
                            if let caption = shot.caption {
                                Text(caption).font(.callout).foregroundStyle(.white.opacity(0.85))
                            }
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: shots.count > 1 ? .always : .never))
                .padding(.vertical, 24)
                VStack {
                    HStack {
                        Spacer()
                        Button { selection = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 34, height: 34).background(Circle().fill(.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close")
                    }
                    Spacer()
                }
                .padding(14)
            }
            .transition(.opacity)
            .accessibilityIdentifier("store.screenshotViewer")
        }
    }

    private func url(_ path: String) -> URL? {
        path.hasPrefix("https://") ? URL(string: path) : URL(string: mediaBase + "/" + path)
    }
}
