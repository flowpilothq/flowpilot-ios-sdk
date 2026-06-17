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
/// The modifier uses a `DragGesture(minimumDistance: 0)` via `simultaneousGesture`
/// to detect press state changes without interfering with existing tap handlers
/// or scroll gestures.
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
            content
                .scaleEffect(pressScale(config))
                .opacity(pressOpacity(config))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressed else { return }
                            let animation: Animation = config.style == "spring"
                                ? .spring(response: config.pressDuration, dampingFraction: 0.6)
                                : .easeIn(duration: config.pressDuration)
                            withAnimation(animation) {
                                isPressed = true
                            }
                        }
                        .onEnded { _ in
                            let animation: Animation = config.style == "spring"
                                ? .spring(response: config.releaseDuration, dampingFraction: 0.6)
                                : .easeOut(duration: config.releaseDuration)
                            withAnimation(animation) {
                                isPressed = false
                            }
                        }
                )
        } else {
            content
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
