import Foundation

// MARK: - Exit Animation Config

/// Resolves exit animation configuration from component props.
///
/// Parses the `exitAnimation` property which defines how a component should
/// animate when leaving the screen. Uses the same grouped format as
/// `AnimationConfig` but reads from the `to` object instead of `from`.
///
/// Expected prop shape:
/// ```json
/// {
///   "exitAnimation": {
///     "trigger": "screenExit",
///     "to": { "opacity": 0, "scale": 0.8, "translateX": 0, "translateY": 20, "rotate": 0 },
///     "duration": 200,
///     "delay": 0,
///     "easing": "ease-in",
///     "haptic": "none"
///   }
/// }
/// ```
///
/// Returns `nil` when the trigger is `"none"` or absent.
struct ExitAnimationConfig {
    /// The trigger that starts the exit animation (e.g., "screenExit", "manual").
    let trigger: String

    /// Final opacity (0-1) on exit.
    let toOpacity: Double

    /// Final scale factor (0-2) on exit.
    let toScale: Double

    /// Final horizontal offset in points on exit.
    let toTranslateX: Double

    /// Final vertical offset in points on exit.
    let toTranslateY: Double

    /// Final rotation in degrees on exit.
    let toRotate: Double

    /// Exit animation duration in seconds.
    let duration: TimeInterval

    /// Exit animation delay in seconds.
    let delay: TimeInterval

    /// Easing curve name (e.g., "ease", "ease-in", "ease-out", "linear", "spring").
    let easing: String

    /// Haptic feedback type (e.g., "none", "light", "medium", "heavy").
    let haptic: String

    // MARK: - Resolution

    /// Resolves an `ExitAnimationConfig` from component props.
    ///
    /// Reads the `exitAnimation` grouped object from props.
    ///
    /// - Parameters:
    ///   - props: The component's props, or `nil`.
    ///   - variableStore: The current variable store for resolving conditional values.
    /// - Returns: A resolved config, or `nil` if the trigger is `"none"` or absent.
    static func resolve(from props: ComponentProps?, variableStore: VariableStore) -> ExitAnimationConfig? {
        guard let props = props else { return nil }

        // Read the exitAnimation grouped object.
        // The value could be a raw dict or wrapped in PropertyValue { "type": "static", "value": { ... } }.
        guard let raw = props.getRaw("exitAnimation") else { return nil }

        var animationDict: [String: Any]?
        if let dict = raw as? [String: Any] {
            if let typeStr = dict["type"] as? String, typeStr == "static",
               let innerValue = dict["value"] as? [String: Any] {
                // It's a PropertyValue wrapper -- unwrap it.
                animationDict = innerValue
            } else if dict["trigger"] != nil {
                // It's a raw exit animation config dict.
                animationDict = dict
            }
        }

        guard let exitDict = animationDict else { return nil }
        return resolveFromGrouped(exitDict)
    }

    // MARK: - Grouped Format

    /// Resolves from the grouped `exitAnimation` object.
    ///
    /// Expected shape:
    /// ```json
    /// {
    ///   "trigger": "screenExit",
    ///   "to": { "opacity": 0, "scale": 0.8, "translateX": 0, "translateY": 20, "rotate": 0 },
    ///   "duration": 200,
    ///   "delay": 0,
    ///   "easing": "ease-in",
    ///   "haptic": "none"
    /// }
    /// ```
    private static func resolveFromGrouped(_ dict: [String: Any]) -> ExitAnimationConfig? {
        let trigger = dict["trigger"] as? String ?? "none"
        if trigger == "none" { return nil }

        let to = dict["to"] as? [String: Any] ?? [:]

        return ExitAnimationConfig(
            trigger: trigger,
            toOpacity: asDouble(to["opacity"]) ?? 1.0,
            toScale: asDouble(to["scale"]) ?? 1.0,
            toTranslateX: asDouble(to["translateX"]) ?? 0,
            toTranslateY: asDouble(to["translateY"]) ?? 0,
            toRotate: asDouble(to["rotate"]) ?? 0,
            duration: (asDouble(dict["duration"]) ?? 200) / 1000,
            delay: (asDouble(dict["delay"]) ?? 0) / 1000,
            easing: dict["easing"] as? String ?? "ease-in",
            haptic: dict["haptic"] as? String ?? "none"
        )
    }

    // MARK: - Helpers

    /// Safely coerces a value to `Double`, handling both `Int` and `Double` JSON types.
    private static func asDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}
