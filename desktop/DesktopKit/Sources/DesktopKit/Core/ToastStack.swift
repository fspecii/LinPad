import SwiftUI

struct ToastStack: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(controller.toasts) { toast in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(toast.message)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if toast.showsProgress {
                            ProgressView().progressViewStyle(.linear).tint(theme.accent)
                        }
                        if let action = toast.action {
                            Button(action.title) {
                                controller.dismissToast(toast.id)
                                action.perform()
                            }
                            .buttonStyle(.bordered)
                            .tint(theme.accent)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 320, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(theme.panelBackground)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                        .strokeBorder(theme.separator, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .toastSwipeToDismiss { controller.dismissToast(toast.id) }
                .onTapGesture { controller.dismissToast(toast.id) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
                .accessibilityAction(named: "Dismiss") { controller.dismissToast(toast.id) }
                .accessibilityIdentifier("desktop.toast")
            }
        }
        .padding(12)
    }
}
