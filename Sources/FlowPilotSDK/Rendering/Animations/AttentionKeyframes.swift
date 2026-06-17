import Foundation

// MARK: - Effect Keyframe

/// A single keyframe point in an effect animation sequence.
///
/// Each keyframe has a `time` position (0.0 - 1.0) within the animation cycle
/// and optional transform values. `nil` values indicate that the property is
/// not animated by this keyframe and should fall back to its default.
typealias AttentionKeyframe = EffectKeyframe

struct EffectKeyframe {
    /// Position within the animation cycle (0.0 = start, 1.0 = end).
    let time: CGFloat

    /// Scale factor (1.0 = no change).
    let scale: CGFloat?

    /// Horizontal translation in points.
    let translateX: CGFloat?

    /// Vertical translation in points.
    let translateY: CGFloat?

    /// Rotation in degrees.
    let rotate: CGFloat?

    /// Opacity (0.0 - 1.0).
    let opacity: CGFloat?

    /// Shadow/glow opacity (0.0 - 1.0).
    let shadowOpacity: CGFloat?
}

// MARK: - Effect Keyframes

/// Provides keyframe definitions and interpolation for named effects.
///
/// Each effect is defined as an array of `EffectKeyframe` points that form a
/// looping animation. The `intensity` parameter (0-100) scales the magnitude of
/// each effect's transforms.
///
/// Supported effects: `pulse`, `heartbeat`, `bounce`, `shake`, `glow`, `float`,
/// `wiggle`, `flash`.
typealias AttentionKeyframes = EffectKeyframes

struct EffectKeyframes {

    /// Returns the keyframe array for the given effect name and intensity.
    ///
    /// - Parameters:
    ///   - effect: The effect name (e.g., "pulse", "bounce", "shake").
    ///   - intensity: The effect intensity (0-100). Higher values produce larger transforms.
    /// - Returns: An array of keyframes describing one full cycle, or an empty array for unknown effects.
    static func keyframes(for effect: String, intensity: CGFloat) -> [EffectKeyframe] {
        let i = intensity // 0-100

        switch effect {
        case "pulse":
            return [
                EffectKeyframe(time: 0, scale: 1, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.5, scale: 1 + i * 0.001, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 1, scale: 1, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
            ]

        case "heartbeat":
            return [
                EffectKeyframe(time: 0, scale: 1, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.15, scale: 1 + i * 0.0015, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.3, scale: 1, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.45, scale: 1 + i * 0.001, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.6, scale: 1, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 1, scale: 1, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
            ]

        case "bounce":
            return [
                EffectKeyframe(time: 0, scale: nil, translateX: nil, translateY: 0, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.4, scale: nil, translateX: nil, translateY: -i * 0.3, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.6, scale: nil, translateX: nil, translateY: i * 0.1, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.8, scale: nil, translateX: nil, translateY: -i * 0.05, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 1, scale: nil, translateX: nil, translateY: 0, rotate: nil, opacity: nil, shadowOpacity: nil),
            ]

        case "shake":
            return [
                EffectKeyframe(time: 0, scale: nil, translateX: 0, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.1, scale: nil, translateX: -i * 0.15, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.3, scale: nil, translateX: i * 0.15, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.5, scale: nil, translateX: -i * 0.1, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.7, scale: nil, translateX: i * 0.1, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.9, scale: nil, translateX: -i * 0.05, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 1, scale: nil, translateX: 0, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: nil),
            ]

        case "glow":
            return [
                EffectKeyframe(time: 0, scale: nil, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: 0),
                EffectKeyframe(time: 0.5, scale: nil, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: i * 0.01),
                EffectKeyframe(time: 1, scale: nil, translateX: nil, translateY: nil, rotate: nil, opacity: nil, shadowOpacity: 0),
            ]

        case "float":
            return [
                EffectKeyframe(time: 0, scale: nil, translateX: nil, translateY: 0, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.5, scale: nil, translateX: nil, translateY: -i * 0.12, rotate: nil, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 1, scale: nil, translateX: nil, translateY: 0, rotate: nil, opacity: nil, shadowOpacity: nil),
            ]

        case "wiggle":
            return [
                EffectKeyframe(time: 0, scale: nil, translateX: nil, translateY: nil, rotate: 0, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.25, scale: nil, translateX: nil, translateY: nil, rotate: i * 0.06, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 0.75, scale: nil, translateX: nil, translateY: nil, rotate: -i * 0.06, opacity: nil, shadowOpacity: nil),
                EffectKeyframe(time: 1, scale: nil, translateX: nil, translateY: nil, rotate: 0, opacity: nil, shadowOpacity: nil),
            ]

        case "flash":
            return [
                EffectKeyframe(time: 0, scale: nil, translateX: nil, translateY: nil, rotate: nil, opacity: 1, shadowOpacity: nil),
                EffectKeyframe(time: 0.5, scale: nil, translateX: nil, translateY: nil, rotate: nil, opacity: 1 - i * 0.005, shadowOpacity: nil),
                EffectKeyframe(time: 1, scale: nil, translateX: nil, translateY: nil, rotate: nil, opacity: 1, shadowOpacity: nil),
            ]

        default:
            return []
        }
    }

    /// Interpolates between keyframes at a given phase within the animation cycle.
    ///
    /// Finds the two surrounding keyframes for the given phase and linearly
    /// interpolates each transform property between them. Properties that are
    /// `nil` on both keyframes fall back to sensible defaults (scale=1, offset=0,
    /// opacity=1, etc.).
    ///
    /// - Parameters:
    ///   - keyframes: The keyframe array for the current effect.
    ///   - phase: The current position in the animation cycle (0.0 - 1.0).
    /// - Returns: An interpolated keyframe with all properties resolved to concrete values.
    static func interpolate(keyframes: [EffectKeyframe], at phase: CGFloat) -> EffectKeyframe {
        guard !keyframes.isEmpty else {
            return EffectKeyframe(time: 0, scale: 1, translateX: 0, translateY: 0, rotate: 0, opacity: 1, shadowOpacity: 0)
        }

        let clampedPhase = min(max(phase, 0), 1)

        // Find the two keyframes to interpolate between.
        var lower = keyframes[0]
        var upper = keyframes[0]

        for i in 0..<keyframes.count {
            if keyframes[i].time <= clampedPhase {
                lower = keyframes[i]
                upper = i + 1 < keyframes.count ? keyframes[i + 1] : keyframes[i]
            }
        }

        // Calculate interpolation factor.
        let range = upper.time - lower.time
        let t: CGFloat = range > 0 ? (clampedPhase - lower.time) / range : 0

        func lerp(_ a: CGFloat?, _ b: CGFloat?, defaultVal: CGFloat) -> CGFloat {
            let av = a ?? defaultVal
            let bv = b ?? defaultVal
            return av + (bv - av) * t
        }

        return AttentionKeyframe(
            time: clampedPhase,
            scale: lerp(lower.scale, upper.scale, defaultVal: 1),
            translateX: lerp(lower.translateX, upper.translateX, defaultVal: 0),
            translateY: lerp(lower.translateY, upper.translateY, defaultVal: 0),
            rotate: lerp(lower.rotate, upper.rotate, defaultVal: 0),
            opacity: lerp(lower.opacity, upper.opacity, defaultVal: 1),
            shadowOpacity: lerp(lower.shadowOpacity, upper.shadowOpacity, defaultVal: 0)
        )
    }
}
