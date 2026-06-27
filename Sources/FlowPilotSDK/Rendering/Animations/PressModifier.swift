import SwiftUI

// MARK: - Press Feedback Config

/// Configuration for press/tap visual feedback on a component.
///
/// Resolved from the `pressFeedback` grouped prop on components. The prop is a
/// dictionary with keys: `style`, `scale`, `opacity`, `pressDuration`, `releaseDuration`.
///
/// Example JSON:
/// ```json
/// {
///   "pressFeedback": {
///     "style": "scale",
///     "scale": 0.96,
///     "opacity": 0.8,
///     "pressDuration": 100,
///     "releaseDuration": 200
///   }
/// }
/// ```
///
/// Supported styles:
///   - `"none"`: No press feedback (returns `nil`).
///   - `"scale"`: Shrinks the component on press.
///   - `"opacity"`: Fades the component on press.
///   - `"highlight"`: Combines scale and opacity.
///   - `"spring"`: Uses spring animation with scale.
struct PressFeedbackConfig {
    /// The feedback style name.
    let style: String

    /// Scale factor applied during press (default: 0.96).
    let scale: CGFloat

    /// Opacity applied during press (default: 0.8).
    let opacity: Double

    /// Duration of the press-down animation in seconds.
    let pressDuration: TimeInterval

    /// Duration of the release animation in seconds.
    let releaseDuration: TimeInterval

    // MARK: - Resolution

    /// Resolves a `PressFeedbackConfig` from component props.
    ///
    /// Reads the `pressFeedback` key from `rawProps` as a dictionary.
    /// Returns `nil` when the style is `"none"` or absent.
    ///
    /// - Parameter props: The component's props, or `nil`.
    /// - Returns: A resolved config, or `nil` if no press feedback is configured.
    static func resolve(from props: ComponentProps?) -> PressFeedbackConfig? {
        guard let props = props else { return nil }

        if let dict = props.getRaw("pressFeedback") as? [String: Any] {
            let style = dict["style"] as? String ?? "none"
            if style == "none" { return nil }

            return PressFeedbackConfig(
                style: style,
                scale: CGFloat(asDouble(dict["scale"]) ?? 0.96),
                opacity: asDouble(dict["opacity"]) ?? 0.8,
                pressDuration: (asDouble(dict["pressDuration"]) ?? 100) / 1000.0,
                releaseDuration: (asDouble(dict["releaseDuration"]) ?? 200) / 1000.0
            )
        }

        return nil
    }

    // MARK: - Helpers

    /// Safely coerces a value to `Double`, handling both `Int` and `Double` JSON types.
    private static func asDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}

// MARK: - Press Modifier

/// Applies press/tap visual feedback to a component.
///
/// Reads the `pressFeedback` property from component props and applies scale
/// and/or opacity changes on press, using the configured animation timing.
///
/// ## Why not `DragGesture(minimumDistance: 0)`
///
/// The obvious way to detect a press is a zero-distance `DragGesture` attached
/// via `simultaneousGesture`. It works for the feedback, but it **breaks
/// scrolling**: a min-distance-0 drag gesture begins on *touch-down* and, even
/// as a simultaneous gesture, claims the touch sequence so an enclosing
/// `ScrollView` (or the UIKit `UIKitScrollView`) can never start its pan when
/// the drag begins *on* the gestured view. The symptom is a list that scrolls
/// from the gaps between cards but is dead the moment you start the drag on a
/// card. (A `TapGesture`, by contrast, fails the instant the finger moves and
/// does not block scrolling — which is why the tap-action `InteractionModifier`
/// is fine.)
///
/// On iOS this modifier instead reads the press state through
/// `PressGestureObserver`, a passive UIKit recognizer that recognizes
/// *simultaneously* with every other gesture and never cancels touches, so
/// taps, the component's own `onPress`, nested inputs, and scrolling all keep
/// working. On platforms without UIKit it falls back to the simultaneous drag
/// gesture (no nested-scroll concern there).
///
/// Animation styles:
///   - `"scale"`: Applies scale transform on press.
///   - `"opacity"`: Applies opacity change on press.
///   - `"highlight"`: Applies both scale and opacity on press.
///   - `"spring"`: Applies scale with spring animation on press.
struct PressModifier: ViewModifier {
    let config: PressFeedbackConfig?

    @State private var isPressed = false

    // MARK: - Body

    func body(content: Content) -> some View {
        if let config = config {
            #if canImport(UIKit)
            content
                // Observe touches behind the content (never participates in
                // hit-testing) so scrolling/taps/onPress are untouched.
                .background(PressGestureObserver(isPressed: $isPressed))
                .scaleEffect(pressScale(config))
                .opacity(pressOpacity(config))
                // `.animation(_:value:)` re-evaluates the animation each time
                // `isPressed` flips, so press uses the press timing and release
                // uses the release timing — matching the old withAnimation calls.
                .animation(pressAnimation(config), value: isPressed)
            #else
            content
                .scaleEffect(pressScale(config))
                .opacity(pressOpacity(config))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressed else { return }
                            withAnimation(pressAnimation(config)) {
                                isPressed = true
                            }
                        }
                        .onEnded { _ in
                            withAnimation(pressAnimation(config)) {
                                isPressed = false
                            }
                        }
                )
            #endif
        } else {
            content
        }
    }

    // MARK: - Animation

    /// The animation to use for the *current* transition. While `isPressed` is
    /// becoming true we want the press-down timing; while it is becoming false
    /// we want the release timing. Because this is recomputed whenever
    /// `isPressed` changes, `.animation(_:value:)` applies the correct one for
    /// each direction.
    private func pressAnimation(_ config: PressFeedbackConfig) -> Animation {
        if isPressed {
            return config.style == "spring"
                ? .spring(response: config.pressDuration, dampingFraction: 0.6)
                : .easeIn(duration: config.pressDuration)
        } else {
            return config.style == "spring"
                ? .spring(response: config.releaseDuration, dampingFraction: 0.6)
                : .easeOut(duration: config.releaseDuration)
        }
    }

    // MARK: - Transform Helpers

    /// Returns the scale factor for the current press state and style.
    private func pressScale(_ config: PressFeedbackConfig) -> CGFloat {
        guard isPressed else { return 1.0 }
        switch config.style {
        case "scale", "highlight", "spring":
            return config.scale
        default:
            return 1.0
        }
    }

    /// Returns the opacity for the current press state and style.
    private func pressOpacity(_ config: PressFeedbackConfig) -> Double {
        guard isPressed else { return 1.0 }
        switch config.style {
        case "opacity", "highlight":
            return config.opacity
        default:
            return 1.0
        }
    }
}

#if canImport(UIKit)
import UIKit

// MARK: - Press Gesture Observer

/// Reports touch-down / touch-up over the modified view as `isPressed` **without
/// consuming the touch or blocking an enclosing scroll view.**
///
/// It mounts a `UILongPressGestureRecognizer` with `minimumPressDuration = 0` on
/// the host window — the same window-level, non-cancelling pattern used by the
/// keyboard-dismiss recognizer in `FlowPresenter`. The recognizer:
///   - recognizes **simultaneously** with every other gesture (its delegate
///     returns `true`), so a `ScrollView`/`UIScrollView` pan and the SwiftUI
///     tap that fires `onPress` both keep working;
///   - has `cancelsTouchesInView = false`, so it never swallows touches headed
///     for the content;
///   - is scoped to this view by testing the touch location against the probe's
///     bounds, and releases the press as soon as the finger travels far enough
///     to be a scroll (or leaves the view).
///
/// The probe itself is an interaction-disabled, transparent `.background` view,
/// so it sizes to the content and can never intercept a hit-test.
struct PressGestureObserver: UIViewRepresentable {
    @Binding var isPressed: Bool

    /// Distance in points a touch may travel before it is treated as a scroll
    /// rather than a press (mirrors a list row's highlight-then-scroll feel).
    var cancelDistance: CGFloat = 12

    func makeCoordinator() -> Coordinator {
        // Replaced on the first updateUIView with a closure bound to `isPressed`.
        Coordinator(setPressed: { _ in })
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window, probe: view)
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.cancelDistance = cancelDistance
        // Refresh the closure each update so it always writes the current binding.
        context.coordinator.setPressed = { pressed in
            if isPressed != pressed { isPressed = pressed }
        }
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: Probe view

    final class ProbeView: UIView {
        var onMoveToWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onMoveToWindow?(window)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var setPressed: (Bool) -> Void
        var cancelDistance: CGFloat = 12

        private weak var window: UIWindow?
        private weak var probe: ProbeView?
        private weak var recognizer: UILongPressGestureRecognizer?
        private var startInWindow: CGPoint?
        private var trackingInside = false

        init(setPressed: @escaping (Bool) -> Void) {
            self.setPressed = setPressed
        }

        func attach(to window: UIWindow?, probe: ProbeView) {
            self.probe = probe
            guard let window = window else { detach(); return }
            // Already attached to this window — nothing to do.
            if self.window === window, recognizer != nil { return }
            detach()
            self.window = window

            let lp = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            lp.minimumPressDuration = 0
            lp.cancelsTouchesInView = false
            lp.delaysTouchesBegan = false
            lp.delaysTouchesEnded = false
            lp.delegate = self
            window.addGestureRecognizer(lp)
            recognizer = lp
        }

        func detach() {
            if let r = recognizer, let w = window {
                w.removeGestureRecognizer(r)
            }
            recognizer = nil
            window = nil
            if trackingInside { setPressed(false) }
            trackingInside = false
            startInWindow = nil
        }

        @objc private func handle(_ gr: UILongPressGestureRecognizer) {
            guard let probe = probe, let window = probe.window else { return }
            let inProbe = gr.location(in: probe)
            let inWindow = gr.location(in: window)

            switch gr.state {
            case .began:
                if probe.bounds.contains(inProbe) {
                    trackingInside = true
                    startInWindow = inWindow
                    setPressed(true)
                } else {
                    trackingInside = false
                }
            case .changed:
                guard trackingInside else { return }
                let movedAway: Bool
                if let start = startInWindow {
                    let dx = inWindow.x - start.x
                    let dy = inWindow.y - start.y
                    movedAway = (dx * dx + dy * dy) > (cancelDistance * cancelDistance)
                } else {
                    movedAway = false
                }
                if movedAway || !probe.bounds.contains(inProbe) {
                    // Became a scroll, or the finger slid off the view.
                    setPressed(false)
                    trackingInside = false
                }
            case .ended, .cancelled, .failed:
                if trackingInside { setPressed(false) }
                trackingInside = false
                startInWindow = nil
            default:
                break
            }
        }

        // MARK: UIGestureRecognizerDelegate

        // Never block — coexist with the scroll pan, the tap that fires onPress,
        // sibling press observers, and any system gesture.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool { true }
    }
}
#endif
