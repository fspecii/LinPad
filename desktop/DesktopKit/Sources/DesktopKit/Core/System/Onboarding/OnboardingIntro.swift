import SwiftUI

/// The first screen: the LinPad mark draws itself while Linux unpacks behind it.
struct OnboardingIntro: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 46
    @ScaledMetric(relativeTo: .title3) private var sublineSize: CGFloat = 20
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            LinPadMark(accent: theme.accent)
                .frame(width: 260, height: 190)
                .accessibilityHidden(true)
            Spacer().frame(height: 36)
            Text("Your iPad is a computer now.")
                .font(.system(size: headlineSize, weight: .bold))
                .tracking(-0.6)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 10)
            Text("Real Linux. Real apps. No VM.")
                .font(.system(size: sublineSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.top, 10)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 8)
            Spacer(minLength: 28)
            BootStatus(controller: controller)
                .opacity(revealed ? 1 : 0)
            Spacer().frame(height: 8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !revealed else { return }
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.easeOut(duration: 0.7).delay(1.5)) { revealed = true }
            }
        }
    }
}

/// "Linux is getting ready…" with a ring that follows the real boot progress: the host's
/// unpacking, then the guest answering, then the Wayland session.
struct BootStatus: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = false

    private var boot: BootProgress { controller.boot }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: boot.isFinished ? 1 : boot.progress)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: boot.progress)
                if boot.isFinished {
                    Image(systemName: "checkmark")
                        .font(.system(size: compact ? 12 : 15, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(Int((boot.progress * 100).rounded()))")
                        .font(.system(size: compact ? 10 : 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.numericText())
                }
            }
            .frame(width: compact ? 30 : 42, height: compact ? 30 : 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(boot.isFinished ? "Linux is ready" : "Linux is getting ready…")
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                if !boot.isFinished, !compact {
                    Text(boot.step)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(minWidth: compact ? 0 : 230, alignment: .leading)
        }
        .animation(reduceMotion ? nil : DesktopMotion.standard, value: boot.isFinished)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boot.isFinished ? "Linux is ready"
                                            : "Linux is getting ready, \(Int((boot.progress * 100).rounded())) percent. \(boot.step)")
        .accessibilityIdentifier("onboarding.bootStatus")
    }
}

/// The LinPad mark, drawn rather than shipped as an image: an iPad outline turns into a
/// landscape desktop with a panel, two tiled windows and a terminal prompt.
struct LinPadMark: View {
    let accent: Color
    /// False draws the finished mark at once (Reduce Motion, small uses).
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    private var finalPhase: Int { 4 }

    var body: some View {
        let landscape = phase >= 2
        let device = landscape ? CGSize(width: 250, height: 176) : CGSize(width: 132, height: 176)
        ZStack {
            // Device outline: drawn first, then turned to landscape.
            RoundedRectangle(cornerRadius: landscape ? 22 : 20, style: .continuous)
                .trim(from: 0, to: phase >= 1 ? 1 : 0)
                .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: device.width, height: device.height)
            // The screen inside the bezel.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(phase >= 2 ? 0.06 : 0))
                if phase >= 3 {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Circle().fill(accent).frame(width: 7, height: 7)
                            Capsule().fill(.white.opacity(0.35)).frame(width: 34, height: 4)
                            Spacer()
                            Capsule().fill(.white.opacity(0.35)).frame(width: 18, height: 4)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 14)
                        .background(Color.white.opacity(0.08))
                        HStack(spacing: 6) {
                            terminalWindow
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            VStack(spacing: 6) {
                                window(lines: 3)
                                window(lines: 2)
                            }
                            .frame(width: 70)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(width: device.width - 20, height: device.height - 20)
            // Front camera on the long edge, as on an iPad in landscape.
            Circle()
                .fill(.white.opacity(phase >= 1 ? 0.6 : 0))
                .frame(width: 5, height: 5)
                .offset(y: -device.height / 2 + 5)
        }
        .frame(width: 260, height: 190)
        .onAppear(perform: start)
    }

    private var terminalWindow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.3)).frame(width: 4, height: 4) }
            }
            HStack(spacing: 4) {
                Text("❯")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                BlinkingCursor(color: .white, animates: animates && !reduceMotion)
            }
            Capsule().fill(.white.opacity(0.18)).frame(width: 60, height: 3)
            Capsule().fill(.white.opacity(0.12)).frame(width: 44, height: 3)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(accent.opacity(0.9), lineWidth: 1.5))
    }

    private func window(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 26, height: 3)
            ForEach(0..<lines, id: \.self) { index in
                Capsule().fill(.white.opacity(0.14)).frame(width: index.isMultiple(of: 2) ? 48 : 36, height: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private func start() {
        guard phase == 0 else { return }
        guard animates, !reduceMotion else {
            phase = finalPhase
            return
        }
        withAnimation(.easeInOut(duration: 0.9)) { phase = 1 }
        withAnimation(.snappy(duration: 0.55).delay(0.95)) { phase = 2 }
        withAnimation(.snappy(duration: 0.5).delay(1.45)) { phase = 3 }
        withAnimation(.easeOut(duration: 0.3).delay(1.9)) { phase = 4 }
    }
}

struct BlinkingCursor: View {
    var color: Color
    var animates = true
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 7, height: 12)
            .opacity(on ? 0.9 : 0.1)
            .onAppear {
                guard animates else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = false }
            }
    }
}

/// Behind the intro: a dark field lit by two slow accent glows and drifting motes.
/// Reduce Motion freezes it.
struct OnboardingBackdrop: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.035, green: 0.04, blue: 0.055)))
                glow(in: &canvas, size: size, center: CGPoint(x: size.width * (0.28 + 0.05 * sin(time / 7)),
                                                              y: size.height * (0.32 + 0.04 * cos(time / 9))),
                     radius: max(size.width, size.height) * 0.55, opacity: 0.30)
                glow(in: &canvas, size: size, center: CGPoint(x: size.width * (0.78 + 0.04 * cos(time / 8)),
                                                              y: size.height * (0.78 + 0.05 * sin(time / 11))),
                     radius: max(size.width, size.height) * 0.45, opacity: 0.18)
                for index in 0..<70 {
                    let seed = Double(index)
                    let x = fract(sin(seed * 12.9898) * 43758.5453)
                    let speed = 0.008 + 0.012 * fract(sin(seed * 78.233) * 12345.678)
                    let y = 1 - fract(fract(cos(seed * 3.17) * 9871.3) + time * speed)
                    let sway = 0.006 * sin(time * 0.6 + seed)
                    let point = CGPoint(x: (x + sway) * size.width, y: y * size.height)
                    let radius = 0.8 + 1.6 * fract(sin(seed * 4.1) * 777.7)
                    let alpha = 0.15 + 0.35 * fract(cos(seed * 2.3) * 555.5)
                    canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                       width: radius * 2, height: radius * 2)),
                                with: .color(accent.opacity(alpha)))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func glow(in canvas: inout GraphicsContext, size: CGSize, center: CGPoint, radius: CGFloat, opacity: Double) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        canvas.fill(Path(ellipseIn: rect),
                    with: .radialGradient(Gradient(colors: [accent.opacity(opacity), accent.opacity(0)]),
                                          center: center, startRadius: 0, endRadius: radius))
    }

    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}
