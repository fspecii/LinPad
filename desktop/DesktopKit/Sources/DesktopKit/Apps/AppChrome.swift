import SwiftUI

/// Small building blocks shared by the built-in apps so they look like one family.

struct InlineBanner: View {
    enum Kind {
        case error, warning, info

        var symbol: String {
            switch self {
            case .error: return "exclamationmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: return Color(red: 1.0, green: 0.42, blue: 0.42)
            case .warning: return Color(red: 1.0, green: 0.76, blue: 0.3)
            case .info: return Color(red: 0.4, green: 0.68, blue: 1.0)
            }
        }
    }

    @Environment(\.desktopTheme) private var theme
    let kind: Kind
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(theme.primaryText)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(kind.tint)
                    .hoverEffect(.highlight)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(kind.tint.opacity(0.13))
        .overlay(alignment: .bottom) {
            Rectangle().fill(kind.tint.opacity(0.35)).frame(height: 1)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ToolbarIconButton: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void

    init(_ symbol: String, help: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? theme.accent : theme.primaryText)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? theme.accent.opacity(0.18) : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .hoverEffect(.highlight)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A capsule text button used for secondary toolbar actions.
struct ToolbarTextButton: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(prominent ? Color.white : theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule().fill(prominent ? theme.accent : theme.primaryText.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .hoverEffect(.highlight)
    }
}

struct AppToolbar<Content: View>: View {
    @Environment(\.desktopTheme) private var theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 4) {
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(theme.titleBarInactive)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }
}

struct AppStatusBar<Content: View>: View {
    @Environment(\.desktopTheme) private var theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            content()
        }
        .font(.caption)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.titleBarInactive)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }
}

struct ThemedSeparator: View {
    @Environment(\.desktopTheme) private var theme
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct AppSearchField: View {
    @Environment(\.desktopTheme) private var theme
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(theme.separator, lineWidth: 1))
    }
}

struct AppEmptyState: View {
    @Environment(\.desktopTheme) private var theme
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.secondaryText.opacity(0.7))
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Clickable column header with a sort direction chevron.
struct SortableHeader: View {
    @Environment(\.desktopTheme) private var theme
    let title: String
    let isActive: Bool
    let ascending: Bool
    var alignment: Alignment = .leading
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                if isActive {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isActive ? theme.primaryText : theme.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}
