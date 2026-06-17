import Foundation

// MARK: - Stagger Config

/// Resolves stagger configuration from a container's component props.
///
/// Supports two prop formats:
///   1. **Grouped** -- a single `stagger` object containing `enabled`, `interval`, `order`, `haptic`.
///   2. **Legacy (flat)** -- individual props like `staggerChildren`, `staggerInterval`, etc.
///
/// The grouped format is preferred when both are present.
/// Returns `nil` when stagger is disabled or absent.
struct StaggerConfig {
    /// Whether stagger is enabled.
    let enabled: Bool

    /// Interval in seconds between each child's animation start.
    let interval: TimeInterval

    /// Order in which children are staggered (e.g., "natural", "reverse", "center-out", "random").
    let order: String

    /// Haptic pattern to play per child during stagger (e.g., "none", "tick", "ramp").
    let haptic: String

    // MARK: - Resolution

    /// Resolves a `StaggerConfig` from component props.
    ///
    /// Tries the new grouped `stagger` object first, then falls back to
    /// legacy flat props (`staggerChildren`, `staggerInterval`, etc.).
    ///
    /// - Parameters:
    ///   - props: The component's props, or `nil`.
    ///   - variableStore: The current variable store for resolving conditional values.
    /// - Returns: A resolved config, or `nil` if stagger is disabled or absent.
    static func resolve(from props: ComponentProps?, variableStore: VariableStore) -> StaggerConfig? {
        guard let props = props else { return nil }

        // Try grouped format first.
        // The value could be a raw dict or wrapped in PropertyValue { "type": "static", "value": { ... } }.
        if let raw = props.getRaw("stagger") {
            var staggerDict: [String: Any]?
            if let dict = raw as? [String: Any] {
                if let typeStr = dict["type"] as? String, typeStr == "static",
                   let innerValue = dict["value"] as? [String: Any] {
                    // It's a PropertyValue wrapper -- unwrap it.
                    staggerDict = innerValue
                } else if dict["enabled"] != nil {
                    // It's a raw stagger config dict.
                    staggerDict = dict
                }
            }

            if let sDict = staggerDict {
                let enabled = sDict["enabled"] as? Bool ?? false
                if !enabled { return nil }
                return StaggerConfig(
                    enabled: true,
                    interval: (asDouble(sDict["interval"]) ?? 80) / 1000,
                    order: sDict["order"] as? String ?? "natural",
                    haptic: sDict["haptic"] as? String ?? "none"
                )
            }
        }

        // Fall back to legacy flat props.
        let enabled = PropertyResolver.resolve(props.staggerChildren, store: variableStore, default: false)
        if !enabled { return nil }

        return StaggerConfig(
            enabled: true,
            interval: PropertyResolver.resolve(props.staggerInterval, store: variableStore, default: 80.0) / 1000,
            order: PropertyResolver.resolve(props.staggerOrder, store: variableStore, default: "natural"),
            haptic: PropertyResolver.resolve(props.staggerHaptic, store: variableStore, default: "none")
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
