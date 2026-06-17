import SwiftUI

// MARK: - Gradient Flow Preset

/// Smoothly shifts gradient colors over time, like a lava-lamp gradient.
func drawGradientFlow(
    ctx: GraphicsContext,
    size: CGSize,
    time: Double,
    params: [String: MotionParamValue]
) {
    let colors = params["colors"]?.stringArrayValue ?? ["#667eea", "#764ba2"]
    let angle = params["angle"]?.doubleValue ?? 135
    let transitionDuration = (params["transitionDuration"]?.doubleValue ?? 4000) / 1000 // to seconds
    let style = params["style"]?.stringValue ?? "smooth"

    guard colors.count >= 2 else { return }

    // Calculate cycle position (0-1)
    let cycleDuration = transitionDuration * Double(colors.count)
    let rawProgress = cycleDuration > 0 ? (time.truncatingRemainder(dividingBy: cycleDuration)) / cycleDuration : 0

    // Apply easing based on style
    let progress: Double
    switch style {
    case "step":
        let steps = Double(colors.count)
        progress = floor(rawProgress * steps) / steps
    case "bounce":
        let t = rawProgress * 2
        if t <= 1 {
            progress = t * t * (3 - 2 * t) / 2
        } else {
            let u = 2 - t
            progress = (u * u * (3 - 2 * u)) / 2
        }
    default: // "smooth"
        progress = rawProgress
    }

    // Convert angle to gradient endpoints
    let angleRad = angle * .pi / 180
    let cosA = cos(angleRad)
    let sinA = sin(angleRad)
    let halfDiag = sqrt(size.width * size.width + size.height * size.height) / 2
    let cx = size.width / 2
    let cy = size.height / 2

    let startPoint = CGPoint(x: cx - cosA * halfDiag, y: cy - sinA * halfDiag)
    let endPoint = CGPoint(x: cx + cosA * halfDiag, y: cy + sinA * halfDiag)

    // Shift colors based on progress
    let colorCount = colors.count
    let shift = progress * Double(colorCount)

    var stops: [Gradient.Stop] = []
    for i in 0..<colorCount {
        let basePos = Double(i) / Double(colorCount - 1)

        let colorIndex = Int(floor(Double(i) + shift)) % colorCount
        let nextColorIndex = Int(floor(Double(i) + shift + 1)) % colorCount
        let frac = shift.truncatingRemainder(dividingBy: 1.0)

        let c1 = hexToRGB(colors[colorIndex])
        let c2 = hexToRGB(colors[nextColorIndex])

        // Interpolate colors
        let r = c1.r + (c2.r - c1.r) * frac
        let g = c1.g + (c2.g - c1.g) * frac
        let b = c1.b + (c2.b - c1.b) * frac

        stops.append(Gradient.Stop(
            color: Color(red: r, green: g, blue: b),
            location: basePos
        ))
    }

    // Draw the gradient
    let gradient = Gradient(stops: stops)
    ctx.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .linearGradient(
            gradient,
            startPoint: startPoint,
            endPoint: endPoint
        )
    )
}
