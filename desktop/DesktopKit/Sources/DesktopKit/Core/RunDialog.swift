import SwiftUI

/// The Alt+F2 dialog: whatever is typed runs in a new Terminal window.
struct RunDialog: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    @State private var command = ""
    @FocusState private var isFieldFocused: Bool

    private var canRun: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Run Command", systemImage: "terminal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            TextField("Command to run in a terminal", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: theme.monospacedFontSize, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .focused($isFieldFocused)
                .onSubmit(run)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(theme.windowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isFieldFocused ? theme.accent : theme.separator, lineWidth: 1)
                }

            HStack {
                Spacer()
                // Escape is bound by the shell for every overlay (DesktopKeyboardShortcuts).
                Button("Cancel") { controller.isRunDialogPresented = false }
                    .buttonStyle(.bordered)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .disabled(!canRun)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.panelBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .onAppear {
            Task { isFieldFocused = true }
        }
    }

    private func run() {
        guard canRun else { return }
        controller.runCommand(command)
    }
}
