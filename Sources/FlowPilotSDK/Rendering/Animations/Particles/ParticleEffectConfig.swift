import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Particle Effect Config

/// Parsed particle effect configuration used by the particle rendering system.
///
/// Created from action userInfo dictionaries, screen-level particle props,
/// or screen timeline particle events. Contains all parameters needed to
/// configure a `CAEmitterLayer` for the effect.
struct ParticleEffectConfig {
    let effect: EffectType
    let duration: TimeInterval        // seconds
    let delay: TimeInterval           // seconds
    let density: Density
    let size: Size
    let colors: [String]              // hex color strings
    let emoji: [String]
    let direction: Direction
    let spread: CGFloat               // degrees
    let gravity: CGFloat
    let speed: CGFloat
    let haptic: String?
    let loop: Bool

    // MARK: - Effect Type

    enum EffectType: String {
        case confetti, sparkles, fireworks, snow, hearts, stars, emoji, bubbles, petals
    }

    // MARK: - Density

    enum Density: String {
        case light, medium, heavy

        var birthRateMultiplier: Float {
            switch self {
            case .light: return 0.5
            case .medium: return 1.0
            case .heavy: return 2.0
            }
        }
    }

    // MARK: - Size

    enum Size: String {
        case small, medium, large

        var scaleMultiplier: CGFloat {
            switch self {
            case .small: return 0.6
            case .medium: return 1.0
            case .large: return 1.5
            }
        }
    }

    // MARK: - Direction

    enum Direction: String {
        case top, bottom, left, right, center, edges
    }

    // MARK: - Per-Effect Defaults

    struct EffectDefaults {
        let direction: Direction
        let duration: TimeInterval     // seconds
        let density: Density
        let colors: [String]
        let gravity: CGFloat
        let spread: CGFloat
        let loop: Bool
    }

    static func defaults(for effect: EffectType) -> EffectDefaults {
        switch effect {
        case .confetti:
            return EffectDefaults(
                direction: .top, duration: 3.0, density: .heavy,
                colors: ["#FF6B6B", "#FFE66D", "#4ECDC4", "#45B7D1", "#96CEB4", "#FF8A80"],
                gravity: 1.0, spread: 120, loop: false
            )
        case .sparkles:
            return EffectDefaults(
                direction: .center, duration: 2.0, density: .medium,
                colors: ["#FFD700", "#FFFFFF"],
                gravity: 0.2, spread: 360, loop: false
            )
        case .fireworks:
            return EffectDefaults(
                direction: .bottom, duration: 4.0, density: .medium,
                colors: ["#FF6B6B", "#FFE66D", "#4ECDC4", "#45B7D1", "#96CEB4", "#FF8A80"],
                gravity: 0.8, spread: 180, loop: false
            )
        case .snow:
            return EffectDefaults(
                direction: .top, duration: 5.0, density: .light,
                colors: ["#FFFFFF", "#E3F2FD"],
                gravity: 0.3, spread: 90, loop: true
            )
        case .hearts:
            return EffectDefaults(
                direction: .bottom, duration: 3.0, density: .medium,
                colors: ["#FF1744", "#FF6090"],
                gravity: -0.3, spread: 120, loop: false
            )
        case .stars:
            return EffectDefaults(
                direction: .center, duration: 2.5, density: .light,
                colors: ["#FFD700", "#FFF176"],
                gravity: 0.1, spread: 360, loop: false
            )
        case .emoji:
            return EffectDefaults(
                direction: .top, duration: 3.0, density: .medium,
                colors: [],
                gravity: 1.0, spread: 120, loop: false
            )
        case .bubbles:
            return EffectDefaults(
                direction: .bottom, duration: 4.0, density: .light,
                colors: ["#42A5F5", "#FFFFFF"],
                gravity: -0.4, spread: 90, loop: true
            )
        case .petals:
            return EffectDefaults(
                direction: .top, duration: 5.0, density: .light,
                colors: ["#F8BBD0", "#FFFFFF"],
                gravity: 0.2, spread: 90, loop: true
            )
        }
    }

    // MARK: - Parsing

    /// Parse from a notification userInfo dictionary or JSON props.
    static func from(dict: [String: Any]) -> ParticleEffectConfig? {
        guard let effectStr = dict["effect"] as? String,
              let effect = EffectType(rawValue: effectStr) else { return nil }

        let defs = defaults(for: effect)

        return ParticleEffectConfig(
            effect: effect,
            duration: (asDouble(dict["duration"]) ?? defs.duration * 1000) / 1000.0,
            delay: (asDouble(dict["delay"]) ?? 0) / 1000.0,
            density: Density(rawValue: dict["density"] as? String ?? "") ?? defs.density,
            size: Size(rawValue: dict["size"] as? String ?? "") ?? .medium,
            colors: (dict["colors"] as? [String]) ?? defs.colors,
            emoji: dict["emoji"] as? [String] ?? ["🎉"],
            direction: Direction(rawValue: dict["direction"] as? String ?? "") ?? defs.direction,
            spread: CGFloat(asDouble(dict["spread"]) ?? Double(defs.spread)),
            gravity: CGFloat(asDouble(dict["gravity"]) ?? Double(defs.gravity)),
            speed: CGFloat(asDouble(dict["speed"]) ?? 1.0),
            haptic: dict["haptic"] as? String,
            loop: dict["loop"] as? Bool ?? defs.loop
        )
    }

    // MARK: - Helpers

    private static func asDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}
