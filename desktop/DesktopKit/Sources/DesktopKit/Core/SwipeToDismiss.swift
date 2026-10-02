import SwiftUI

/// When a swipe on a notification counts as "dismiss": far enough, or a fling.
enum SwipeDismissal {
    /// Points a toast must travel, or the speed (pt/s) that throws it off regardless.
    static let distance: CGFloat = 90
    static let flingSpeed: CGFloat = 600

    /// Toasts leave to the right or upward.
    static func dismissesToast(translation: CGSize, predictedEnd: CGSize) -> Bool {
        let towardEdge = max(translation.width, -translation.height)
        let predicted = max(predictedEnd.width, -predictedEnd.height)
        return towardEdge > distance || (predicted - towardEdge) * 4 > flingSpeed && towardEdge > 10
    }

    /// Movement against the allowed direction stretches only a little.
    static func rubberBand(_ value: CGFloat) -> CGFloat {
        value >= 0 ? value : -pow(-value, 0.7)
    }

    /// Notification center rows: a short swipe left reveals Clear, a long one dismisses.
    enum RowOutcome: Equatable { case close, reveal, dismiss }

    static let revealWidth: CGFloat = 76

    static func rowOutcome(translation: CGFloat, predictedEnd: CGFloat, rowWidth: CGFloat) -> RowOutcome {
        if -translation > rowWidth * 0.6 || -predictedEnd > rowWidth { return .dismiss }
        if -translation > revealWidth / 2 { return .reveal }
        return .close
    }
}

/// Swipe a toast right or up to dismiss it, with rubber-banding the other way.
struct ToastSwipe: ViewModifier {
    let onDismiss: () -> Void
    @State private var offset: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(offset)
            .opacity(1 - min(max(offset.width, -offset.height, 0) / 240, 0.6))
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        offset = CGSize(width: SwipeDismissal.rubberBand(value.translation.width),
                                        height: -SwipeDismissal.rubberBand(-value.translation.height))
                    }
                    .onEnded { value in
                        if SwipeDismissal.dismissesToast(translation: value.translation,
                                                          predictedEnd: value.predictedEndTranslation) {
                            let away = value.translation.width >= -value.translation.height
                                ? CGSize(width: 420, height: offset.height) : CGSize(width: offset.width, height: -300)
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { offset = away }
                            onDismiss()
                        } else {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) { offset = .zero }
                        }
                    }
            )
    }
}

/// Swipe a notification center row left to reveal Clear; swipe all the way to dismiss it.
struct NoticeRowSwipe: ViewModifier {
    let onDismiss: () -> Void
    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    @State private var width: CGFloat = 340
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button {
                    onDismiss()
                } label: {
                    Text("Clear")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: max(-offset, SwipeDismissal.revealWidth))
                        .frame(maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("desktop.notification.clear")
            }
            content
                .offset(x: offset)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    offset = min(settled + value.translation.width, 0)
                }
                .onEnded { value in
                    let outcome = SwipeDismissal.rowOutcome(translation: settled + value.translation.width,
                                                            predictedEnd: settled + value.predictedEndTranslation.width,
                                                            rowWidth: width)
                    let animation: Animation? = reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)
                    switch outcome {
                    case .dismiss:
                        withAnimation(animation) { offset = -width }
                        onDismiss()
                    case .reveal:
                        withAnimation(animation) { offset = -SwipeDismissal.revealWidth }
                    case .close:
                        withAnimation(animation) { offset = 0 }
                    }
                    settled = offset
                }
        )
    }
}

extension View {
    func toastSwipeToDismiss(_ onDismiss: @escaping () -> Void) -> some View {
        modifier(ToastSwipe(onDismiss: onDismiss))
    }

    func noticeSwipeToDismiss(_ onDismiss: @escaping () -> Void) -> some View {
        modifier(NoticeRowSwipe(onDismiss: onDismiss))
    }
}
