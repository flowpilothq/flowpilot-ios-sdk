import Foundation

// MARK: - Animation Config

/// Resolves animation configuration from component props.
///
/// Supports two prop formats:
///   1. **Grouped** -- a single `animation` object containing `trigger`, `from`, `duration`, etc.
///   2. **Legacy (flat)** -- individual props like `animateOn`, `animOpacity`, `animScale`, etc.
///
/// The grouped format is preferred when both are present.
/// Returns `nil` when the effective trigger is `"none"` or absent.
struct AnimationConfig {
    /// The trigger that starts the animation (e.g., "appear", "screenEnter", "tap").
    let trigger: String

    /// Starting opacity (0-1). Final value is always 1.
    let fromOpacity: Double

    /// Starting scale factor (0-2). Final value is always 1.
    let fromScale: Double

    /// Starting horizontal offset in points. Final value is always 0.
    let fromTranslateX: Double

    /// Starting vertical offset in points. Final value is always 0.
    let fromTranslateY: Double

    /// Starting rotation in degrees. Final value is always 0.
    let fromRotate: Double

    /// Animation duration in seconds.
    let duration: TimeInterval

    /// Animation delay in seconds.
    let delay: TimeInterval

    /// Easing curve name (e.g., "ease", "ease-in", "ease-out", "linear", "spring").
    let easing: String

    /// Haptic feedback type (e.g., "none", "light", "medium", "heavy").
    let haptic: String

    /// When to fire the haptic relative to the animation ("start" or "end").
    let hapticTiming: String

    /// Whether this component should auto-chain after the previous sibling's animation finishes.
    let chainAfterPrevious: Bool

    // MARK: - Resolution

    /// Resolves an `AnimationConfig` from component props.
    ///
    /// Tries the new grouped `animation` object first, then falls back to
    /// legacy flat props (`animateOn`, `animOpacity`, etc.).
    ///
    /// - Parameters:
    ///   - props: The component's props, or `nil`.
    ///   - variableStore: The current variable store for resolving conditional values.
    /// - Returns: A resolved config, or `nil` if the trigger is `"none"` or absent.
    static func resolve(from props: ComponentProps?, variableStore: VariableStore) -> AnimationConfig? {
        guard let props = props else { return nil }

        // Try grouped format first.
        // The value could be a raw dict or wrapped in PropertyValue { "type": "static", "value": { ... } }.
        if let raw = props.getRaw("animation") {
            var animationDict: [String: Any]?
            if let dict = raw as? [String: Any] {
                if let typeStr = dict["type"] as? String, typeStr == "static",
                   let innerValue = dict["value"] as? [String: Any] {
                    // It's a PropertyValue wrapper -- unwrap it.
                    animationDict = innerValue
                } else if dict["trigger"] != nil {
                    // It's a raw animation config dict.
                    animationDict = dict
                }
            }

            if let animDict = animationDict {
                return resolveFromGrouped(animDict)
            }
        }

        // Fall back to legacy flat props.
        return resolveFromLegacy(props, variableStore: variableStore)
    }

    // MARK: - Grouped Format

    /// Resolves from the new grouped `animation` object.
    ///
    /// Expected shape:
    /// ```json
    /// {
    ///   "trigger": "appear",
    ///   "from": { "opacity": 0, "scale": 0.8, "translateX": 0, "translateY": 20, "rotate": 0 },
    ///   "duration": 300,
    ///   "delay": 0,
    ///   "easing": "ease",
    ///   "haptic": "none",
    ///   "hapticTiming": "start"
    /// }
    /// ```
    private static func resolveFromGrouped(_ dict: [String: Any]) -> AnimationConfig? {
        let trigger = dict["trigger"] as? String ?? "none"
        if trigger == "none" { return nil }

        let from = dict["from"] as? [String: Any] ?? [:]

        return AnimationConfig(
            trigger: trigger,
            fromOpacity: asDouble(from["opacity"]) ?? 1.0,
            fromScale: asDouble(from["scale"]) ?? 1.0,
            fromTranslateX: asDouble(from["translateX"]) ?? 0,
            fromTranslateY: asDouble(from["translateY"]) ?? 0,
            fromRotate: asDouble(from["rotate"]) ?? 0,
            duration: (asDouble(dict["duration"]) ?? 300) / 1000,
            delay: (asDouble(dict["delay"]) ?? 0) / 1000,
            easing: dict["easing"] as? String ?? "ease",
            haptic: dict["haptic"] as? String ?? "none",
            hapticTiming: dict["hapticTiming"] as? String ?? "start",
            chainAfterPrevious: dict["chainAfterPrevious"] as? Bool ?? false
        )
    }

    // MARK: - Legacy Format

    /// Resolves from legacy flat props (`animateOn`, `animOpacity`, etc.).
    private static func resolveFromLegacy(_ props: ComponentProps, variableStore: VariableStore) -> AnimationConfig? {
        let trigger = PropertyResolver.resolve(props.animateOn, store: variableStore, default: "none")
        if trigger == "none" { return nil }

        return AnimationConfig(
            trigger: trigger,
            fromOpacity: PropertyResolver.resolve(props.animOpacity, store: variableStore, default: 100.0) / 100,
            fromScale: PropertyResolver.resolve(props.animScale, store: variableStore, default: 100.0) / 100,
            fromTranslateX: PropertyResolver.resolve(props.animMoveX, store: variableStore, default: 0.0),
            fromTranslateY: PropertyResolver.resolve(props.animMoveY, store: variableStore, default: 0.0),
            fromRotate: PropertyResolver.resolve(props.animRotate, store: variableStore, default: 0.0),
            duration: PropertyResolver.resolve(props.animDuration, store: variableStore, default: 300.0) / 1000,
            delay: PropertyResolver.resolve(props.animDelay, store: variableStore, default: 0.0) / 1000,
            easing: PropertyResolver.resolve(props.animEasing, store: variableStore, default: "ease"),
            haptic: PropertyResolver.resolve(props.hapticType, store: variableStore, default: "none"),
            hapticTiming: {
                let hapticTrigger = PropertyResolver.resolve(props.hapticTrigger, store: variableStore, default: "onAnimStart")
                return hapticTrigger == "onAnimEnd" ? "end" : "start"
            }(),
            chainAfterPrevious: false  // legacy props never had chaining
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
