import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Attention Config

/// Configuration for a looping attention animation effect.
///
/// Resolved from the `attention` grouped prop on components. The prop is a
/// dictionary with keys: `effect`, `duration`, `delay`, `repeat`, `intensity`.
///
/// Example JSON:
/// ```json
/// {
///   "attention": {
///     "effect": "pulse",
///     "duration": 1000,
///     "delay": 0,
///     "repeat": "infinite",
///     "intensity": 50
///   }
/// }
/// ```
struct AttentionConfig {
    /// The effect name (e.g., "pulse", "bounce", "shake", "glow", "float", "heartbeat", "wiggle", "flash").
    let effect: String

    /// Duration of one animation cycle in seconds.
    let duration: TimeInterval

    /// Delay before the first cycle starts, in seconds.
    let delay: TimeInterval

    /// Number of cycles to run. -1 means infinite looping.
    let repeatCount: Int

    /// Effect intensity (0-100). Higher values produce larger transforms.
    let intensity: CGFloat

    // MARK: - Resolution

    /// Resolves an `AttentionConfig` from component props.
    ///
    /// Reads the `attention` key from `rawProps` as a dictionary.
    /// Returns `nil` when the effect is `"none"` or absent.
    ///
    /// - Parameter props: The component's props, or `nil`.
    /// - Returns: A resolved config, or `nil` if no attention effect is configured.
    static func resolve(from props: ComponentProps?) -> AttentionConfig? {
        guard let props = props else { return nil }

        // Read grouped attention object.
        if let attentionDict = props.getRaw("attention") as? [String: Any] {
            let effect = attentionDict["effect"] as? String ?? "none"
            if effect == "none" { return nil }

            let duration = (asDouble(attentionDict["duration"]) ?? 1000) / 1000.0
            let delay = (asDouble(attentionDict["delay"]) ?? 0) / 1000.0
            let intensity = CGFloat(asDouble(attentionDict["intensity"]) ?? 50)

            let repeatCount: Int
            if let repeatStr = attentionDict["repeat"] as? String, repeatStr == "infinite" {
                repeatCount = -1
            } else if let repeatNum = attentionDict["repeat"] as? Int {
                repeatCount = repeatNum
            } else {
                repeatCount = -1
            }

            return AttentionConfig(
                effect: effect,
                duration: duration,
                delay: delay,
                repeatCount: repeatCount,
                intensity: intensity
            )
        }

        return nil
    }

    // MARK: - Helpers

    /// Safely coerces a value to `Double`, handling both `Int` and `Double` JSON types.
    private static func asDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}

// MARK: - Attention Modifier

/// Applies a looping keyframe-driven attention animation to a component.
///
/// Reads the `attention` property from component props and uses a Timer-driven
/// phase loop (0 -> 1, repeating) with the `AttentionKeyframes` interpolator
/// to apply transforms: `scaleEffect`, `offset`, `rotationEffect`, `opacity`,
/// and `shadow`.
///
/// Respects `UIAccessibility.isReduceMotionEnabled` -- when enabled, the
/// animation is suppressed entirely.
///
/// Supports:
///   - Configurable delay before the animation starts
///   - Finite repeat counts (stops after N cycles)
///   - Infinite looping (repeatCount == -1)
struct AttentionModifier: ViewModifier {
    let config: AttentionConfig?

    @State private var phase: CGFloat = 0
    @State private var currentCycle: Int = 0
    @State private var isActive: Bool = false
    @State private var timer: Timer?

    // MARK: - Body

    func body(content: Content) -> some View {
        if let config = config, config.effect != "none" {
            let keyframes = AttentionKeyframes.keyframes(for: config.effect, intensity: config.intensity)
            let interpolated = AttentionKeyframes.interpolate(keyframes: keyframes, at: phase)

            content
                .scaleEffect(interpolated.scale ?? 1)
                .offset(x: interpolated.translateX ?? 0, y: interpolated.translateY ?? 0)
                .rotationEffect(.degrees(Double(interpolated.rotate ?? 0)))
                .opacity(Double(interpolated.opacity ?? 1))
                .shadow(
                    color: Color.blue.opacity(Double(interpolated.shadowOpacity ?? 0)),
                    radius: CGFloat(config.intensity) * 0.3
                )
                .onAppear {
                    startAnimation(config: config)
                }
                .onDisappear {
                    stopAnimation()
                }
        } else {
            content
        }
    }

    // MARK: - Animation Control

    /// Starts the attention animation after the configured delay.
    ///
    /// Respects Reduce Motion -- if enabled, the animation is not started.
    private func startAnimation(config: AttentionConfig) {
        // Respect reduce motion accessibility setting.
        if isReduceMotionEnabled { return }

        let startDelay = config.delay
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) {
            isActive = true
            runAnimationLoop(config: config)
        }
    }

    /// Runs the timer-driven animation loop, advancing the phase each frame.
    ///
    /// Uses a 60fps timer to produce smooth keyframe interpolation. When a cycle
    /// completes, checks the repeat count and either resets or stops.
    private func runAnimationLoop(config: AttentionConfig) {
        // Use a display-link-like timer for smooth animation.
        let frameRate: TimeInterval = 1.0 / 60.0
        let totalFrames = config.duration / frameRate
        var frameCount: CGFloat = 0

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: frameRate, repeats: true) { t in
            frameCount += 1
            let newPhase = frameCount / CGFloat(totalFrames)

            if newPhase >= 1.0 {
                // Cycle complete.
                phase = 0
                frameCount = 0
                currentCycle += 1

                // Check if we should stop.
                if config.repeatCount != -1 && currentCycle >= config.repeatCount {
                    t.invalidate()
                    timer = nil
                    isActive = false
                    return
                }
            } else {
                phase = newPhase
            }
        }
    }

    /// Stops the animation and cleans up the timer.
    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        isActive = false
    }

    // MARK: - Accessibility

    /// Whether the system's Reduce Motion accessibility setting is enabled.
    private var isReduceMotionEnabled: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }
}
