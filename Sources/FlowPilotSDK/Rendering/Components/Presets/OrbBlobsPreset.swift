import SwiftUI

// MARK: - Orb Blobs Preset

/// Soft gaussian-blurred ellipses drifting on sinusoidal paths.

private struct OrbState {
    let cx: Double      // center x (0-1 normalized)
    let cy: Double      // center y (0-1 normalized)
    let rx: Double      // radius x (px)
    let ry: Double      // radius y (px)
    let color: String
    let phaseX: Double
    let phaseY: Double
    let speedX: Double
    let speedY: Double
    let radiusPhase: Double
}

private let SIZE_MAP: [String: Double] = [
    "small": 0.2,
    "medium": 0.35,
    "large": 0.5
]

private let MOVEMENT_MAP: [String: Double] = [
    "gentle": 0.15,
    "moderate": 0.35,
    "energetic": 0.6
]

/// Generates deterministic orb positions (seeded, no jumping on re-render)
private func generateOrbs(
    count: Int,
    colors: [String],
    sizeFactor: Double,
    width: Double,
    height: Double
) -> [OrbState] {
    var orbs: [OrbState] = []
    let baseRadius = min(width, height) * sizeFactor

    for i in 0..<count {
        let fi = Double(i)
        let angle = (fi / Double(count)) * .pi * 2
        orbs.append(OrbState(
            cx: 0.5 + 0.25 * cos(angle + fi),
            cy: 0.5 + 0.25 * sin(angle + fi * 0.7),
            rx: baseRadius * (0.8 + 0.4 * Double((i * 7 + 3) % 5) / 5),
            ry: baseRadius * (0.7 + 0.5 * Double((i * 11 + 1) % 5) / 5),
            color: colors[i % colors.count],
            phaseX: (fi * 2.39996).truncatingRemainder(dividingBy: .pi * 2),
            phaseY: (fi * 1.61803).truncatingRemainder(dividingBy: .pi * 2),
            speedX: 0.3 + Double((i * 3 + 2) % 7) / 10,
            speedY: 0.2 + Double((i * 5 + 1) % 7) / 10,
            radiusPhase: (fi * 0.8).truncatingRemainder(dividingBy: .pi * 2)
        ))
    }
    return orbs
}

func drawOrbBlobs(
    ctx: GraphicsContext,
    size: CGSize,
    time: Double,
    params: [String: MotionParamValue]
) {
    let colors = params["colors"]?.stringArrayValue ?? ["#667eea", "#764ba2", "#f093fb"]
    let count = min(max(params["count"]?.intValue ?? 3, 2), 6)
    let sizeKey = params["size"]?.stringValue ?? "medium"
    let blur = params["blur"]?.doubleValue ?? 80
    let movementKey = params["movement"]?.stringValue ?? "gentle"

    let sizeFactor = SIZE_MAP[sizeKey] ?? 0.35
    let movementFactor = MOVEMENT_MAP[movementKey] ?? 0.15

    let width = Double(size.width)
    let height = Double(size.height)

    let orbs = generateOrbs(
        count: count,
        colors: colors,
        sizeFactor: sizeFactor,
        width: width,
        height: height
    )

    for orb in orbs {
        // Animate position with sinusoidal movement
        let x = (orb.cx + movementFactor * sin(time * orb.speedX + orb.phaseX)) * width
        let y = (orb.cy + movementFactor * cos(time * orb.speedY + orb.phaseY)) * height

        // Subtle radius breathing
        let breathe = 1 + 0.1 * sin(time * 0.5 + orb.radiusPhase)
        let rx = orb.rx * breathe
        let ry = orb.ry * breathe

        let rgb = hexToRGB(orb.color)

        // Create radial gradient for the orb
        let gradient = Gradient(stops: [
            .init(color: Color(red: rgb.r, green: rgb.g, blue: rgb.b).opacity(0.85), location: 0),
            .init(color: Color(red: rgb.r, green: rgb.g, blue: rgb.b).opacity(0.5), location: 0.4),
            .init(color: Color(red: rgb.r, green: rgb.g, blue: rgb.b).opacity(0), location: 1.0)
        ])

        let center = CGPoint(x: x, y: y)

        // Apply blur per-orb context copy
        var orbCtx = ctx
        orbCtx.addFilter(.blur(radius: blur))

        let ellipsePath = Path(ellipseIn: CGRect(
            x: x - rx,
            y: y - ry,
            width: rx * 2,
            height: ry * 2
        ))

        orbCtx.fill(
            ellipsePath,
            with: .radialGradient(
                gradient,
                center: center,
                startRadius: 0,
                endRadius: max(rx, ry)
            )
        )
    }
}
