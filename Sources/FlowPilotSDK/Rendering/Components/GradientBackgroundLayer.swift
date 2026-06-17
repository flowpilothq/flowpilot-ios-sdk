import SwiftUI

// MARK: - Gradient Background Layer

/// The raw gradient fill (linear / radial / conic) for a given definition,
/// WITHOUT any safe-area handling. Shared by the screen-background layer (which
/// adds `.ignoresSafeArea()`) and per-component `backgroundGradient` fills
/// (applied as a `.background { }`, clipped by the component's corner shape).
struct GradientFill: View {
    let gradient: GradientDefinition

    var body: some View {
        let stops = gradientStops(from: gradient.colors)
        let swiftGradient = Gradient(stops: stops)

        switch gradient.type {
        case .linear:
            let points = angleToUnitPoints(angleDegrees: gradient.angle ?? 180)
            LinearGradient(
                gradient: swiftGradient,
                startPoint: points.start,
                endPoint: points.end
            )

        case .radial:
            let center = UnitPoint(
                x: (gradient.centerX ?? 50) / 100.0,
                y: (gradient.centerY ?? 50) / 100.0
            )
            GeometryReader { geo in
                RadialGradient(
                    gradient: swiftGradient,
                    center: center,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.7
                )
            }

        case .conic:
            let center = UnitPoint(
                x: (gradient.centerX ?? 50) / 100.0,
                y: (gradient.centerY ?? 50) / 100.0
            )
            AngularGradient(
                gradient: swiftGradient,
                center: center
            )
        }
    }
}

struct GradientBackgroundLayer: View {
    let gradient: GradientDefinition

    var body: some View {
        GradientFill(gradient: gradient)
            .ignoresSafeArea()
    }
}

// MARK: - Gradient Utilities

/// Convert CSS angle (0° = up, 90° = right, clockwise) to SwiftUI start/end UnitPoints
func angleToUnitPoints(angleDegrees: Double) -> (start: UnitPoint, end: UnitPoint) {
    let rad = angleDegrees * .pi / 180

    // The gradient line direction vector
    let dx = sin(rad)
    let dy = -cos(rad)

    // Project to UnitPoint space (0-1)
    let start = UnitPoint(x: 0.5 - dx * 0.5, y: 0.5 - dy * 0.5)
    let end = UnitPoint(x: 0.5 + dx * 0.5, y: 0.5 + dy * 0.5)

    return (start, end)
}

func gradientStops(from colors: [GradientStop]) -> [Gradient.Stop] {
    colors.map { stop in
        Gradient.Stop(
            color: Color(hex: stop.color) ?? .clear,
            location: stop.position / 100.0
        )
    }
}
