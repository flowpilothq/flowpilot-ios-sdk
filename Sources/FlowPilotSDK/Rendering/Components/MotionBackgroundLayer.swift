import SwiftUI

// MARK: - Motion Background Layer

/// Renders animated motion background presets using SwiftUI Canvas.
/// Targets ~30fps for battery efficiency.
struct MotionBackgroundLayer: View {
    let motion: MotionBackground

    @State private var isActive = true

    // Track app lifecycle to pause when backgrounded
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || motion.paused == true)) { context in
            Canvas { ctx, size in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let speed = motion.speed ?? 1.0
                // Use a modular time to avoid floating-point precision issues after long runtimes
                let time = elapsed.truncatingRemainder(dividingBy: 86400) * speed

                switch motion.preset {
                case .gradientFlow:
                    drawGradientFlow(ctx: ctx, size: size, time: time, params: motion.params)
                case .orbBlobs:
                    drawOrbBlobs(ctx: ctx, size: size, time: time, params: motion.params)
                case .aurora:
                    drawAurora(ctx: ctx, size: size, time: time, params: motion.params)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: scenePhase) { newPhase in
            isActive = (newPhase == .active)
        }
    }
}

// MARK: - Motion Static Fallback

/// Static fallback for reduced motion: renders the preset's first frame
struct MotionStaticFallback: View {
    let motion: MotionBackground

    var body: some View {
        Canvas { ctx, size in
            switch motion.preset {
            case .gradientFlow:
                drawGradientFlow(ctx: ctx, size: size, time: 0, params: motion.params)
            case .orbBlobs:
                drawOrbBlobs(ctx: ctx, size: size, time: 0, params: motion.params)
            case .aurora:
                drawAurora(ctx: ctx, size: size, time: 0, params: motion.params)
            }
        }
        .ignoresSafeArea()
    }
}
