import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Animation Modifier

/// Applies appear and exit animations to components with optional stagger and haptic support.
///
/// Supports five independent transform channels that run in parallel:
///   - **Opacity** -- 0-1, maps to SwiftUI opacity
///   - **Scale** -- factor where 1 = no change, maps to `scaleEffect`
///   - **Translate X** -- horizontal offset in points
///   - **Translate Y** -- vertical offset in points
///   - **Rotation** -- degrees, maps to `rotationEffect`
///
/// Animation configuration is resolved via `AnimationConfig`, which tries the
/// new grouped `animation` object first, then falls back to legacy flat props
/// (`animateOn`, `animOpacity`, `animScale`, etc.).
///
/// Exit animations are resolved via `ExitAnimationConfig` from the `exitAnimation`
/// prop. When a `ScreenLifecyclePublisher` fires its exit signal and the component
/// has a `screenExit` trigger, the component animates to its exit state.
///
/// Timing is controlled by `duration`, `delay`, and `easing` from the config.
/// An `animationSpeed` multiplier scales all durations and delays (e.g., 0.5 = half speed).
///
/// Reads `StaggerContext` from the SwiftUI environment to get stagger and
/// chain delay information:
///   - **Stagger**: `effectiveDelay = delay + (staggerIndex * staggerInterval)`
///   - **Chain**: `effectiveDelay = chainDelay + staggerDelay` (chainDelay already
///     includes the component's own delay)
///
/// When `UIAccessibility.isReduceMotionEnabled` is true, stagger and chain
/// delays are removed (all children appear simultaneously) and animations
/// skip to the final state. Haptics still fire, as they are accessibility-positive.
struct AnimationModifier: ViewModifier {
    let props: ComponentProps?
    let variableStore: VariableStore
    let animationSpeed: Double

    @State private var hasAppeared = false
    @State private var isExiting = false
    @State private var exitCancellable: AnyCancellable?

    /// Stagger context injected by a parent stagger container (StackView) via the environment.
    @Environment(\.staggerContext) private var staggerContext

    /// Screen lifecycle publisher injected by FlowPresenter. Optional -- not all
    /// presentation paths inject this (e.g., standalone component previews).
    @Environment(\.screenLifecyclePublisher) private var screenLifecycle

    init(props: ComponentProps?, variableStore: VariableStore, animationSpeed: Double = 1.0) {
        self.props = props
        self.variableStore = variableStore
        self.animationSpeed = animationSpeed
    }

    // MARK: - Resolved Configs

    /// Resolves the enter animation configuration from props (grouped format first, then legacy).
    private var enterConfig: AnimationConfig? {
        AnimationConfig.resolve(from: props, variableStore: variableStore)
    }

    /// Resolves the exit animation configuration from props.
    private var exitConfig: ExitAnimationConfig? {
        ExitAnimationConfig.resolve(from: props, variableStore: variableStore)
    }

    /// Effective speed multiplier (clamped to a sane range).
    private var effectiveSpeed: Double {
        max(0.01, animationSpeed)
    }

    // MARK: - Body

    func body(content: Content) -> some View {
        let enter = enterConfig
        let exit = exitConfig
        let hasEnter = enter != nil && enter!.trigger == "appear"
        let hasExit = exit != nil

        if hasEnter || hasExit {
            let _ = Logger.shared.debug("[AnimationModifier] animateOn=\(enter?.trigger ?? "none") exitTrigger=\(exit?.trigger ?? "none") staggerIndex=\(staggerContext.index) speed=\(animationSpeed)")

            content
                .opacity(currentOpacity(enter: enter, exit: exit))
                .scaleEffect(currentScale(enter: enter, exit: exit))
                .offset(x: currentOffsetX(enter: enter, exit: exit), y: currentOffsetY(enter: enter, exit: exit))
                .rotationEffect(.degrees(currentRotation(enter: enter, exit: exit)))
                .onAppear {
                    // Guard against duplicate onAppear calls (can happen with
                    // List/ScrollView recycling or navigation transitions).
                    guard !hasAppeared else { return }

                    if hasEnter, let config = enter {
                        performEnterAnimation(config: config)
                    } else {
                        // No enter animation, just mark as appeared.
                        hasAppeared = true
                    }

                    // Subscribe to screen exit signal if we have an exit config.
                    if let exit = exit, exit.trigger == "screenExit" {
                        subscribeToScreenExit(exitConfig: exit)
                    }
                }
                .onDisappear {
                    // Clean up exit subscription.
                    exitCancellable?.cancel()
                    exitCancellable = nil
                }
        } else {
            content
        }
    }

    // MARK: - Current Transform Values

    /// Resolves the current opacity based on enter/exit state.
    private func currentOpacity(enter: AnimationConfig?, exit: ExitAnimationConfig?) -> Double {
        if isExiting, let exit = exit {
            return exit.toOpacity
        }
        if let enter = enter, enter.trigger == "appear", !hasAppeared {
            return enter.fromOpacity
        }
        return 1.0
    }

    /// Resolves the current scale based on enter/exit state.
    private func currentScale(enter: AnimationConfig?, exit: ExitAnimationConfig?) -> CGFloat {
        if isExiting, let exit = exit {
            return CGFloat(exit.toScale)
        }
        if let enter = enter, enter.trigger == "appear", !hasAppeared {
            return CGFloat(enter.fromScale)
        }
        return 1.0
    }

    /// Resolves the current X offset based on enter/exit state.
    private func currentOffsetX(enter: AnimationConfig?, exit: ExitAnimationConfig?) -> CGFloat {
        if isExiting, let exit = exit {
            return CGFloat(exit.toTranslateX)
        }
        if let enter = enter, enter.trigger == "appear", !hasAppeared {
            return CGFloat(enter.fromTranslateX)
        }
        return 0
    }

    /// Resolves the current Y offset based on enter/exit state.
    private func currentOffsetY(enter: AnimationConfig?, exit: ExitAnimationConfig?) -> CGFloat {
        if isExiting, let exit = exit {
            return CGFloat(exit.toTranslateY)
        }
        if let enter = enter, enter.trigger == "appear", !hasAppeared {
            return CGFloat(enter.fromTranslateY)
        }
        return 0
    }

    /// Resolves the current rotation based on enter/exit state.
    private func currentRotation(enter: AnimationConfig?, exit: ExitAnimationConfig?) -> Double {
        if isExiting, let exit = exit {
            return exit.toRotate
        }
        if let enter = enter, enter.trigger == "appear", !hasAppeared {
            return enter.fromRotate
        }
        return 0
    }

    // MARK: - Enter Animation

    /// Performs the enter (appear) animation with stagger and chain support.
    private func performEnterAnimation(config: AnimationConfig) {
        let reduceMotion = isReduceMotionEnabled

        // Compute the total delay: base delay + stagger offset + chain offset.
        // When Reduce Motion is enabled, skip stagger/chain delays so
        // all children appear simultaneously.
        let staggerDelay = reduceMotion ? 0 : (Double(staggerContext.index) * staggerContext.interval)
        let chainDelay = reduceMotion ? 0 : staggerContext.chainDelay
        // priorDelay cascades earlier-staggered siblings' enter delays onto this
        // child so a delayed sibling pushes it back instead of being overtaken.
        let priorDelay = reduceMotion ? 0 : staggerContext.priorDelay
        let totalDelay: TimeInterval
        if chainDelay > 0 {
            // chainDelay already includes the component's own delay
            totalDelay = (chainDelay + staggerDelay + priorDelay) / effectiveSpeed
        } else {
            totalDelay = (config.delay + staggerDelay + priorDelay) / effectiveSpeed
        }

        Logger.shared.debug("[AnimationModifier] onAppear firing: chainDelay=\(chainDelay)s staggerDelay=\(staggerDelay)s totalDelay=\(totalDelay)s duration=\(config.duration / effectiveSpeed)s reduceMotion=\(reduceMotion)")

        if reduceMotion {
            // Skip animation, jump to final state immediately.
            // Use a zero-duration animation so SwiftUI still
            // processes the state change in the correct frame.
            withAnimation(.linear(duration: 0)) {
                hasAppeared = true
            }
        } else {
            withAnimation(makeAnimation(duration: config.duration, easing: config.easing, totalDelay: totalDelay)) {
                hasAppeared = true
            }
        }

        // Schedule haptic feedback (fires even when Reduce Motion
        // is enabled, as haptics are accessibility-positive).
        scheduleHaptic(type: config.haptic, timing: config.hapticTiming, totalDelay: totalDelay, duration: config.duration / effectiveSpeed)
    }

    // MARK: - Exit Animation

    /// Subscribes to the screen lifecycle exit publisher.
    private func subscribeToScreenExit(exitConfig: ExitAnimationConfig) {
        guard let lifecycle = screenLifecycle else { return }

        exitCancellable = lifecycle.exitPublisher
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [exitConfig] in
                performExitAnimation(config: exitConfig)
            }
    }

    /// Performs the exit animation, transitioning to the exit state.
    private func performExitAnimation(config: ExitAnimationConfig) {
        let reduceMotion = isReduceMotionEnabled

        let delay = config.delay / effectiveSpeed

        Logger.shared.debug("[AnimationModifier] exit firing: delay=\(delay)s duration=\(config.duration / effectiveSpeed)s reduceMotion=\(reduceMotion)")

        if reduceMotion {
            withAnimation(.linear(duration: 0)) {
                isExiting = true
            }
        } else {
            withAnimation(makeAnimation(duration: config.duration, easing: config.easing, totalDelay: delay)) {
                isExiting = true
            }
        }

        // Fire exit haptic at animation start.
        if config.haptic != "none" {
            HapticManager.shared.fire(config.haptic, after: delay)
        }
    }

    // MARK: - Animation Timing

    /// Builds the SwiftUI `Animation` with the effective total delay baked in.
    ///
    /// The `animationSpeed` multiplier is applied to the duration so that
    /// faster/slower playback is possible from screen-level settings.
    ///
    /// - Parameters:
    ///   - duration: The raw animation duration in seconds (before speed scaling).
    ///   - easing: The easing curve name.
    ///   - totalDelay: The combined base delay + stagger delay in seconds (already speed-scaled).
    /// - Returns: A configured `Animation` with easing and delay applied.
    private func makeAnimation(duration: TimeInterval, easing: String, totalDelay: TimeInterval) -> Animation {
        let scaledDuration = duration / effectiveSpeed

        var animation: Animation

        switch easing {
        case "ease":
            animation = .easeInOut(duration: scaledDuration)
        case "ease-in":
            animation = .easeIn(duration: scaledDuration)
        case "ease-out":
            animation = .easeOut(duration: scaledDuration)
        case "ease-in-out":
            animation = .easeInOut(duration: scaledDuration)
        case "linear":
            animation = .linear(duration: scaledDuration)
        case "spring":
            animation = .spring(response: scaledDuration, dampingFraction: 0.7)
        default:
            animation = .easeInOut(duration: scaledDuration)
        }

        return animation.delay(totalDelay)
    }

    // MARK: - Haptic Feedback

    /// Schedules haptic feedback based on timing preference.
    ///
    /// - Parameters:
    ///   - type: The haptic type string.
    ///   - timing: When to fire ("start" or "end").
    ///   - totalDelay: The total animation delay (base + stagger) in seconds.
    ///   - duration: The speed-scaled animation duration in seconds.
    private func scheduleHaptic(type: String, timing: String, totalDelay: TimeInterval, duration: TimeInterval) {
        guard type != "none" else { return }

        switch timing {
        case "start":
            // Fire when the animation begins (after the full delay).
            HapticManager.shared.fire(type, after: totalDelay)

        case "end":
            // Fire when the animation completes (delay + duration).
            let endTime = totalDelay + duration
            HapticManager.shared.fire(type, after: endTime)

        default:
            // Fire at start by default.
            HapticManager.shared.fire(type, after: totalDelay)
        }
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

// MARK: - Screen Lifecycle Environment Key

/// Environment key for optionally passing a `ScreenLifecyclePublisher` to child views.
///
/// Using an optional environment value (rather than `@EnvironmentObject`) so that
/// components can render without crashing when no publisher is injected (e.g.,
/// standalone previews, custom component hosts).
private struct ScreenLifecycleKey: EnvironmentKey {
    static let defaultValue: ScreenLifecyclePublisher? = nil
}

// MARK: - Animation Speed Environment Key

/// Environment key for passing the screen-level animation speed multiplier to child views.
private struct AnimationSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    /// The screen lifecycle publisher injected by `FlowPresenterView`.
    ///
    /// `nil` when no publisher has been injected (safe for standalone use).
    var screenLifecyclePublisher: ScreenLifecyclePublisher? {
        get { self[ScreenLifecycleKey.self] }
        set { self[ScreenLifecycleKey.self] = newValue }
    }

    /// The animation speed multiplier injected by `FlowPresenterView`.
    ///
    /// Defaults to 1.0 (normal speed). Values < 1 slow down, values > 1 speed up.
    var animationSpeedMultiplier: Double {
        get { self[AnimationSpeedKey.self] }
        set { self[AnimationSpeedKey.self] = newValue }
    }
}
