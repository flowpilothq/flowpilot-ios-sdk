import Foundation

// MARK: - Animation Notification Names

/// Notification names used for triggering animations and particle effects
/// from actions. These are posted by `ActionExecutor` and observed by
/// the relevant view modifiers / screen-level handlers.
extension Notification.Name {
    /// Posted when a `triggerAnimation` action fires.
    ///
    /// **userInfo keys**:
    /// - `"targetComponentId"`: `String` -- the component to animate
    /// - `"stepId"`: `String?` -- optional step ID to trigger (new step-based format)
    /// - `"animation"`: `String` -- one of `"enter"`, `"exit"`, `"attention"` (legacy, kept for backward compat)
    static let triggerComponentAnimation = Notification.Name("com.flowpilot.triggerComponentAnimation")

    /// Posted when a `triggerParticle` action fires or a screen timeline schedules a particle event.
    ///
    /// **userInfo keys** (all optional except `"effect"`):
    /// - `"effect"`: `String` -- the particle effect name (e.g., "confetti", "sparkles", "fireworks",
    ///   "snow", "hearts", "stars", "emoji", "bubbles", "petals")
    /// - `"duration"`: `Int` -- duration in milliseconds
    /// - `"delay"`: `Int` -- delay before starting in milliseconds
    /// - `"colors"`: `[String]` -- array of color hex strings
    /// - `"emoji"`: `[String]` -- array of emoji characters (for "emoji" effect)
    /// - `"density"`: `String` -- "light", "medium", or "heavy"
    /// - `"size"`: `String` -- "small", "medium", or "large"
    /// - `"direction"`: `String` -- "top", "bottom", "left", "right", "center", or "edges"
    /// - `"spread"`: `Double` -- emission cone angle in degrees (0–360)
    /// - `"gravity"`: `Double` -- gravity multiplier (0–2, negative = float up)
    /// - `"speed"`: `Double` -- velocity multiplier (0–2)
    /// - `"haptic"`: `String` -- "none", "light", "medium", "heavy", or "success"
    /// - `"loop"`: `Bool` -- whether the effect loops continuously
    static let triggerParticleEffect = Notification.Name("com.flowpilot.triggerParticleEffect")
}
