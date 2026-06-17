import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit

// MARK: - Particle Emitter Factory

/// Creates configured `CAEmitterLayer` instances for each particle effect type.
///
/// Each effect type maps to specific emitter position, shape, cell count, and physics
/// parameters. The factory reads a `ParticleEffectConfig` and produces a ready-to-use
/// `CAEmitterLayer` that can be added to a view's layer hierarchy.
enum ParticleEmitterFactory {

    // MARK: - Max Particles (Performance Budget)

    private static let maxSimultaneousEmitters = 3

    /// Creates a configured CAEmitterLayer for the given effect config and container bounds.
    static func makeEmitter(
        config: ParticleEffectConfig,
        bounds: CGRect
    ) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.frame = bounds

        // Render mode depends on effect
        switch config.effect {
        case .sparkles, .stars:
            emitter.renderMode = .additive
        default:
            emitter.renderMode = .oldestFirst
        }

        configureEmitterPosition(emitter, direction: config.direction, bounds: bounds)
        emitter.emitterCells = makeCells(config: config)

        return emitter
    }

    // MARK: - Emitter Position

    private static func configureEmitterPosition(
        _ emitter: CAEmitterLayer,
        direction: ParticleEffectConfig.Direction,
        bounds: CGRect
    ) {
        switch direction {
        case .top:
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: -10)
            emitter.emitterSize = CGSize(width: bounds.width * 1.2, height: 1)
            emitter.emitterShape = .line

        case .bottom:
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.height + 10)
            emitter.emitterSize = CGSize(width: bounds.width * 1.2, height: 1)
            emitter.emitterShape = .line

        case .center:
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            emitter.emitterSize = CGSize(width: 1, height: 1)
            emitter.emitterShape = .point

        case .left:
            emitter.emitterPosition = CGPoint(x: -10, y: bounds.midY)
            emitter.emitterSize = CGSize(width: 1, height: bounds.height)
            emitter.emitterShape = .line

        case .right:
            emitter.emitterPosition = CGPoint(x: bounds.width + 10, y: bounds.midY)
            emitter.emitterSize = CGSize(width: 1, height: bounds.height)
            emitter.emitterShape = .line

        case .edges:
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            emitter.emitterSize = bounds.size
            emitter.emitterShape = .rectangle
        }
    }

    // MARK: - Cell Creation Dispatch

    private static func makeCells(config: ParticleEffectConfig) -> [CAEmitterCell] {
        switch config.effect {
        case .confetti:
            return makeConfettiCells(config: config)
        case .sparkles:
            return makeSparkleCells(config: config)
        case .fireworks:
            return makeFireworkCells(config: config)
        case .snow:
            return makeSnowCells(config: config)
        case .hearts:
            return makeShapeCells(config: config, shape: .heart)
        case .stars:
            return makeShapeCells(config: config, shape: .star)
        case .emoji:
            return makeEmojiCells(config: config)
        case .bubbles:
            return makeBubbleCells(config: config)
        case .petals:
            return makePetalCells(config: config)
        }
    }

    // MARK: - Confetti

    private static func makeConfettiCells(config: ParticleEffectConfig) -> [CAEmitterCell] {
        let birthRate: Float = 40 * config.density.birthRateMultiplier
        let scale = 1.5 * config.size.scaleMultiplier
        let colors = parseColors(config.colors)

        return colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = ParticleShapes.rectangle(color: color).cgImage
            cell.birthRate = birthRate / Float(colors.count)
            cell.lifetime = 4.0
            cell.lifetimeRange = 1.0
            cell.velocity = 200 * CGFloat(config.speed)
            cell.velocityRange = 80
            cell.emissionLongitude = emissionAngle(for: config.direction)
            cell.emissionRange = config.spread * .pi / 180 / 2
            cell.yAcceleration = 150 * CGFloat(config.gravity)
            cell.spin = 3.0
            cell.spinRange = 6.0
            cell.scale = CGFloat(scale)
            cell.scaleRange = CGFloat(scale * 0.4)
            cell.alphaSpeed = -0.2
            return cell
        }
    }

    // MARK: - Sparkles

    private static func makeSparkleCells(config: ParticleEffectConfig) -> [CAEmitterCell] {
        let birthRate: Float = 25 * config.density.birthRateMultiplier
        let scale = 1.0 * config.size.scaleMultiplier
        let colors = parseColors(config.colors)

        return colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = ParticleShapes.circle(color: color, size: 8).cgImage
            cell.birthRate = birthRate / Float(colors.count)
            cell.lifetime = 1.5
            cell.lifetimeRange = 0.5
            cell.velocity = 100 * CGFloat(config.speed)
            cell.velocityRange = 60
            cell.emissionLongitude = 0
            cell.emissionRange = .pi * 2 // full circle
            cell.yAcceleration = 30 * CGFloat(config.gravity)
            cell.scale = CGFloat(scale)
            cell.scaleRange = CGFloat(scale * 0.3)
            cell.scaleSpeed = -CGFloat(scale * 0.4)
            cell.alphaSpeed = -0.6
            return cell
        }
    }

    // MARK: - Fireworks

    private static func makeFireworkCells(config: ParticleEffectConfig) -> [CAEmitterCell] {
        let birthRate: Float = 30 * config.density.birthRateMultiplier
        let scale = 1.0 * config.size.scaleMultiplier
        let colors = parseColors(config.colors)

        return colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = ParticleShapes.circle(color: color, size: 6).cgImage
            cell.birthRate = birthRate / Float(colors.count)
            cell.lifetime = 3.0
            cell.lifetimeRange = 1.0
            // Fireworks shoot upward from bottom then arc
            cell.velocity = 300 * CGFloat(config.speed)
            cell.velocityRange = 100
            cell.emissionLongitude = emissionAngle(for: config.direction)
            cell.emissionRange = config.spread * .pi / 180 / 2
            cell.yAcceleration = 200 * CGFloat(config.gravity)
            cell.scale = CGFloat(scale)
            cell.scaleRange = CGFloat(scale * 0.4)
            cell.alphaSpeed = -0.3
            cell.spin = 2.0
            cell.spinRange = 4.0
            return cell
        }
    }

    // MARK: - Snow

    private static func makeSnowCells(config: ParticleEffectConfig) -> [CAEmitterCell] {
        let birthRate: Float = 15 * config.density.birthRateMultiplier
        let colors = parseColors(config.colors)

        return colors.enumerated().map { index, color in
            let cell = CAEmitterCell()
            let isSmall = index % 2 == 0
            let baseSize: CGFloat = isSmall ? 6 : 10
            let scale = (isSmall ? 0.6 : 0.8) * config.size.scaleMultiplier

            cell.contents = ParticleShapes.circle(color: color, size: baseSize).cgImage
            cell.birthRate = birthRate / Float(colors.count)
            cell.lifetime = 8.0
            cell.lifetimeRange = 3.0
            cell.velocity = 40 * CGFloat(config.speed)
            cell.velocityRange = 20
            cell.emissionLongitude = .pi / 2  // downward
            cell.emissionRange = .pi / 6
            cell.yAcceleration = 20 * CGFloat(config.gravity)
            cell.xAcceleration = 5  // slight drift
            cell.scale = CGFloat(scale)
            cell.scaleRange = CGFloat(scale * 0.3)
            cell.alphaSpeed = -0.05
            cell.spin = 0.5
            cell.spinRange = 1.0
            return cell
        }
    }

    // MARK: - Shape Cells (Hearts & Stars)

    private enum ShapeType {
        case heart, star
    }

    private static func makeShapeCells(config: ParticleEffectConfig, shape: ShapeType) -> [CAEmitterCell] {
        let birthRate: Float = 20 * config.density.birthRateMultiplier
        let scale = 1.5 * config.size.scaleMultiplier
        let colors = parseColors(config.colors)

        return colors.map { color in
            let cell = CAEmitterCell()
            switch shape {
            case .heart:
                cell.contents = ParticleShapes.heart(color: color).cgImage
            case .star:
                cell.contents = ParticleShapes.star(color: color).cgImage
            }
            cell.birthRate = birthRate / Float(colors.count)
            cell.lifetime = 4.0
            cell.lifetimeRange = 1.0
            cell.velocity = 120 * CGFloat(config.speed)
            cell.velocityRange = 50
            cell.emissionLongitude = emissionAngle(for: config.direction)
            cell.emissionRange = config.spread * .pi / 180 / 2
            cell.yAcceleration = CGFloat(config.gravity) < 0
                ? CGFloat(config.gravity) * 100   // float up
                : CGFloat(config.gravity) * 80    // fall down
            cell.scale = CGFloat(scale)
            cell.scaleRange = CGFloat(scale * 0.3)
            cell.alphaSpeed = -0.2
            cell.spin = 0.3
            cell.spinRange = 0.6
            return cell
        }
    }

    // MARK: - Emoji

    private static func makeEmojiCells(config: ParticleEffectConfig) -> [CAEmitterCell] {
        let birthRate: Float = 20 * config.density.birthRateMultiplier
        let emojiSize: CGFloat = config.size == .small ? 24 : (config.size == .large ? 44 : 32)

        return config.emoji.map { char in
            let cell = CAEmitterCell()
            cell.contents = ParticleShapes.emoji(char, size: emojiSize).cgImage
            cell.birthRate = birthRate / Float(config.emoji.count)
            cell.lifetime = 4.0
            cell.lifetimeRange = 1.0
            cell.velocity = 150 * CGFloat(config.speed)
            cell.velocityRange = 60
            cell.emissionLongitude = emissionAngle(for: config.direction)
            cell.emissionRange = config.spread * .pi / 180 / 2
            cell.yAcceleration = 120 * CGFloat(config.gravity)
            cell.scale = 1.0
            cell.scaleRange = 0.3
            cell.alphaSpeed = -0.2
            cell.spin = 1.0
            cell.spinRange = 2.0
            return cell
        }
    }

    // MARK: - Bubbles

    private static func makeBubbleCells(config: ParticleEffectConfig) -> [CAEmitterCell] {
        let birthRate: Float = 10 * config.density.birthRateMultiplier
        let colors = parseColors(config.colors)

        return colors.map { color in
            let cell = CAEmitterCell()
            let bubbleColor = color.withAlphaComponent(0.3)
            let size: CGFloat = config.size == .small ? 8 : (config.size == .large ? 18 : 12)
            cell.contents = ParticleShapes.circle(color: bubbleColor, size: size).cgImage
            cell.birthRate = birthRate / Float(colors.count)
            cell.lifetime = 6.0
            cell.lifetimeRange = 2.0
            cell.velocity = 60 * CGFloat(config.speed)
            cell.velocityRange = 30
            cell.emissionLongitude = -.pi / 2 // upward
            cell.emissionRange = config.spread * .pi / 180 / 2
            cell.yAcceleration = CGFloat(config.gravity) * 60 // negative gravity = float up
            cell.xAcceleration = 3 // slight wobble
            let scale = 1.2 * config.size.scaleMultiplier
            cell.scale = CGFloat(scale)
            cell.scaleRange = CGFloat(scale * 0.4)
            cell.scaleSpeed = CGFloat(scale * 0.1)
            cell.alphaSpeed = -0.1
            return cell
        }
    }

    // MARK: - Petals

    private static func makePetalCells(config: ParticleEffectConfig) -> [CAEmitterCell] {
        let birthRate: Float = 12 * config.density.birthRateMultiplier
        let scale = 1.5 * config.size.scaleMultiplier
        let colors = parseColors(config.colors)

        return colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = ParticleShapes.petal(color: color).cgImage
            cell.birthRate = birthRate / Float(colors.count)
            cell.lifetime = 7.0
            cell.lifetimeRange = 2.0
            cell.velocity = 50 * CGFloat(config.speed)
            cell.velocityRange = 25
            cell.emissionLongitude = .pi / 2 // downward
            cell.emissionRange = config.spread * .pi / 180 / 2
            cell.yAcceleration = 25 * CGFloat(config.gravity)
            cell.xAcceleration = 10 // gentle drift
            cell.scale = CGFloat(scale)
            cell.scaleRange = CGFloat(scale * 0.3)
            cell.alphaSpeed = -0.08
            cell.spin = 1.5
            cell.spinRange = 3.0
            return cell
        }
    }

    // MARK: - Helpers

    /// Converts the particle direction to an emission longitude angle.
    private static func emissionAngle(for direction: ParticleEffectConfig.Direction) -> CGFloat {
        switch direction {
        case .top:      return .pi / 2      // downward
        case .bottom:   return -.pi / 2     // upward
        case .left:     return 0            // rightward
        case .right:    return .pi          // leftward
        case .center:   return 0            // radial (emissionRange handles spread)
        case .edges:    return 0            // varies per edge
        }
    }

    /// Parses hex color strings into UIColor instances.
    private static func parseColors(_ hexStrings: [String]) -> [UIColor] {
        let colors = hexStrings.compactMap { UIColor.fp_fromHex($0) }
        // Fallback to white if no valid colors
        return colors.isEmpty ? [.white] : colors
    }
}

// MARK: - UIColor Hex Parsing

private extension UIColor {
    /// Creates a UIColor from a hex string (e.g., "#FF6B6B", "4ECDC4").
    static func fp_fromHex(_ hex: String) -> UIColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 || hexSanitized.count == 8 else { return nil }

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        if hexSanitized.count == 8 {
            return UIColor(
                red: CGFloat((rgbValue & 0xFF000000) >> 24) / 255.0,
                green: CGFloat((rgbValue & 0x00FF0000) >> 16) / 255.0,
                blue: CGFloat((rgbValue & 0x0000FF00) >> 8) / 255.0,
                alpha: CGFloat(rgbValue & 0x000000FF) / 255.0
            )
        } else {
            return UIColor(
                red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
                green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
                blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
                alpha: 1.0
            )
        }
    }
}

#endif
