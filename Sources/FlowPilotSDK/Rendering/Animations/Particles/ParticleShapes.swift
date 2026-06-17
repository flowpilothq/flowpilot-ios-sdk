import Foundation

#if canImport(UIKit)
import UIKit

// MARK: - Particle Shapes

/// Generates small CGImage/UIImage assets for particle emitter cells programmatically.
///
/// Instead of bundling image assets, particle shapes (rectangles, circles, hearts, stars, etc.)
/// are drawn on-demand and cached in an `NSCache` to avoid redundant rendering.
enum ParticleShapes {

    // MARK: - Cache

    private static let cache = NSCache<NSString, UIImage>()

    // MARK: - Rectangle (Confetti)

    /// A small colored rectangle for confetti particles.
    static func rectangle(color: UIColor, size: CGFloat = 12) -> UIImage {
        let key = "rect_\(color.hexString)_\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let w = size
        let h = size * 0.6
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Circle

    /// A small colored circle for sparkle/snow/bubble particles.
    static func circle(color: UIColor, size: CGFloat = 10) -> UIImage {
        let key = "circle_\(color.hexString)_\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Heart

    /// A heart shape for heart particle effects.
    static func heart(color: UIColor, size: CGFloat = 14) -> UIImage {
        let key = "heart_\(color.hexString)_\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            color.setFill()
            let path = UIBezierPath()
            let s = size
            // Heart shape using cubic bezier curves
            path.move(to: CGPoint(x: s * 0.5, y: s * 0.9))
            path.addCurve(
                to: CGPoint(x: s * 0.05, y: s * 0.35),
                controlPoint1: CGPoint(x: s * 0.1, y: s * 0.7),
                controlPoint2: CGPoint(x: 0, y: s * 0.5)
            )
            path.addCurve(
                to: CGPoint(x: s * 0.5, y: s * 0.2),
                controlPoint1: CGPoint(x: s * 0.1, y: s * 0.1),
                controlPoint2: CGPoint(x: s * 0.35, y: s * 0.1)
            )
            path.addCurve(
                to: CGPoint(x: s * 0.95, y: s * 0.35),
                controlPoint1: CGPoint(x: s * 0.65, y: s * 0.1),
                controlPoint2: CGPoint(x: s * 0.9, y: s * 0.1)
            )
            path.addCurve(
                to: CGPoint(x: s * 0.5, y: s * 0.9),
                controlPoint1: CGPoint(x: s, y: s * 0.5),
                controlPoint2: CGPoint(x: s * 0.9, y: s * 0.7)
            )
            path.close()
            path.fill()
        }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Star

    /// A 5-point star shape for star particle effects.
    static func star(color: UIColor, size: CGFloat = 14) -> UIImage {
        let key = "star_\(color.hexString)_\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            color.setFill()
            let path = starPath(in: CGRect(x: 0, y: 0, width: size, height: size), points: 5)
            path.fill()
        }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Petal

    /// An elliptical petal shape for petal particle effects.
    static func petal(color: UIColor, size: CGFloat = 12) -> UIImage {
        let key = "petal_\(color.hexString)_\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let w = size * 0.5
        let h = size
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let image = renderer.image { ctx in
            color.setFill()
            let path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: w, height: h))
            path.fill()
            // Add a slight gradient effect by overlaying a lighter version
            UIColor.white.withAlphaComponent(0.3).setFill()
            let innerPath = UIBezierPath(ovalIn: CGRect(x: w * 0.15, y: h * 0.1, width: w * 0.5, height: h * 0.6))
            innerPath.fill()
        }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Emoji

    /// Renders an emoji character as a UIImage.
    static func emoji(_ character: String, size: CGFloat = 20) -> UIImage {
        let key = "emoji_\(character)_\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.8)
            ]
            let str = character as NSString
            let textSize = str.size(withAttributes: attributes)
            let origin = CGPoint(
                x: (size - textSize.width) / 2,
                y: (size - textSize.height) / 2
            )
            str.draw(at: origin, withAttributes: attributes)
        }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Star Path Helper

    private static func starPath(in rect: CGRect, points: Int) -> UIBezierPath {
        let path = UIBezierPath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.4

        let angleIncrement = CGFloat.pi * 2 / CGFloat(points * 2)
        let startAngle = -CGFloat.pi / 2 // Start from top

        for i in 0..<(points * 2) {
            let radius = i.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = startAngle + CGFloat(i) * angleIncrement
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.close()
        return path
    }
}

// MARK: - UIColor Hex Helper

private extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }
}

#endif
