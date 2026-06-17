import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Step Animator

/// Applies the unified step-based animation timeline to a component.
///
/// Replaces the old `AnimationModifier` + `AttentionModifier` combo with a single
/// modifier that processes the component's `AnimationTimeline` — handling appear,
/// exit, attention effects, action-triggered steps, and tap-triggered steps.
///
/// **How it works:**
/// 1. On appear, applies the `from` state immediately
/// 2. Processes automatic steps (onAppear, afterPrevious, withPrevious) in sequence
/// 3. Registers reactive steps (onScreenExit, onAction, onTap) as listeners
/// 4. Tracks current state — reactive steps animate FROM whatever the current state is
///
/// **Stagger support:** Reads `StaggerContext` from the environment to add stagger
/// delay to the first `onAppear` step.
///
/// **Accessibility:** When `UIAccessibility.isReduceMotionEnabled` is true, skips
/// to the final state of automatic steps immediately. Haptics still fire.
struct StepAnimator: ViewModifier {
    let props: ComponentProps?
    let variableStore: VariableStore
    let animationSpeed: Double
    let componentId: String

    // MARK: - State

    @State private var currentOpacity: Double = 1
    @State private var currentScale: Double = 1
    @State private var currentTranslateX: Double = 0
    @State private var currentTranslateY: Double = 0
    @State private var currentRotate: Double = 0

    // Effect animation state
    @State private var effectPhase: CGFloat = 0
    @State private var effectTimer: Timer?
    @State private var activeEffect: EffectConfig?

    @State private var hasAppeared = false
    @State private var exitCancellable: AnyCancellable?
    @State private var actionCancellable: AnyCancellable?
    @State private var scheduledTimers: [Timer] = []

    // MARK: - Environment

    @Environment(\.staggerContext) private var staggerContext
    @Environment(\.screenLifecyclePublisher) private var screenLifecycle
    @Environment(\.timelineDelays) private var timelineDelays

    init(props: ComponentProps?, variableStore: VariableStore, animationSpeed: Double = 1.0, componentId: String = "") {
        self.props = props
        self.variableStore = variableStore
        self.animationSpeed = animationSpeed
        self.componentId = componentId
    }

    // MARK: - Resolved Timeline

    private var timeline: AnimationTimeline? {
        AnimationTimeline.resolve(from: props, variableStore: variableStore)
    }

    private var effectiveSpeed: Double {
        max(0.01, animationSpeed)
    }

    // MARK: - Body

    func body(content: Content) -> some View {
        let tl = timeline

        if let tl = tl, !tl.steps.isEmpty {
            let effectKeyframes: [EffectKeyframe]? = {
                guard let effect = activeEffect else { return nil }
                return EffectKeyframes.keyframes(for: effect.type, intensity: effect.intensity)
            }()

            let interpolated: EffectKeyframe? = {
                guard let kf = effectKeyframes, !kf.isEmpty else { return nil }
                return EffectKeyframes.interpolate(keyframes: kf, at: effectPhase)
            }()

            let hasTapSteps = tl.steps.contains { step in
                if case .onTap = step.trigger { return true }
                return false
            }

            // Compute display values: use `from` state before first appear,
            // then use current animated state after. This ensures the component
            // renders at its `from` state on the FIRST frame (before onAppear),
            // avoiding a flash of the natural state.
            let displayOpacity = displayValue(
                current: currentOpacity,
                from: tl.from?.opacity,
                natural: 1.0,
                interpolated: interpolated?.opacity.map { Double($0) }
            )
            let displayScale = displayValue(
                current: currentScale,
                from: tl.from?.scale,
                natural: 1.0,
                interpolated: interpolated?.scale.map { Double($0) }
            )
            let displayTranslateX = displayValue(
                current: currentTranslateX,
                from: tl.from?.translateX,
                natural: 0.0,
                interpolated: interpolated?.translateX.map { Double($0) }
            )
            let displayTranslateY = displayValue(
                current: currentTranslateY,
                from: tl.from?.translateY,
                natural: 0.0,
                interpolated: interpolated?.translateY.map { Double($0) }
            )
            let displayRotate = displayValue(
                current: currentRotate,
                from: tl.from?.rotate,
                natural: 0.0,
                interpolated: interpolated?.rotate.map { Double($0) }
            )

            content
                .opacity(displayOpacity)
                .scaleEffect(CGFloat(displayScale))
                .offset(x: CGFloat(displayTranslateX),
                        y: CGFloat(displayTranslateY))
                .rotationEffect(.degrees(displayRotate))
                .shadow(
                    color: interpolated.flatMap { kf in
                        kf.shadowOpacity.map { Color.blue.opacity(Double($0)) }
                    } ?? .clear,
                    radius: interpolated?.shadowOpacity != nil ? CGFloat(activeEffect?.intensity ?? 0) * 0.3 : 0
                )
                .ifCondition(hasTapSteps) { view in
                    view.simultaneousGesture(
                        TapGesture().onEnded {
                            let tapSteps = tl.steps.filter { step in
                                if case .onTap = step.trigger { return true }
                                return false
                            }
                            for step in tapSteps {
                                self.runStep(step)
                            }
                        }
                    )
                }
                .onAppear {
                    guard !hasAppeared else { return }
                    hasAppeared = true
                    setupTimeline(tl)
                }
                .onDisappear {
                    cleanup()
                }
        } else {
            content
        }
    }

    /// Computes the display value for a transform property.
    ///
    /// Before `onAppear`, returns the `from` value (so the component starts hidden/transformed).
    /// After `onAppear`, returns the animated `current` value, optionally multiplied/offset
    /// by the effect interpolation.
    private func displayValue(current: Double, from: Double?, natural: Double, interpolated: Double?) -> Double {
        if !hasAppeared {
            // Before first appear: show the `from` state, or natural if no `from`.
            return from ?? natural
        }
        // After appear: use the animated current state, with optional effect overlay.
        if let effect = interpolated {
            // For scale/opacity (multiplicative), multiply. For translate/rotate (additive), add.
            // We use a simple approach: if natural is 1 it's multiplicative, if 0 it's additive.
            if natural == 1.0 {
                return current * effect
            } else {
                return current + effect
            }
        }
        return current
    }

    // MARK: - Timeline Setup

    private func setupTimeline(_ tl: AnimationTimeline) {
        let reduceMotion = isReduceMotionEnabled

        // Set @State properties to the `from` state. Before onAppear, the
        // `displayValue` method was already rendering these values. Now that
        // hasAppeared is true, the @State properties drive the display.
        if let from = tl.from {
            currentOpacity = from.opacity
            currentScale = from.scale
            currentTranslateX = from.translateX
            currentTranslateY = from.translateY
            currentRotate = from.rotate
        }

        if reduceMotion {
            // Skip to natural state immediately
            withAnimation(.linear(duration: 0)) {
                applyNaturalState()
            }
            // Fire haptics for first step even in reduce motion
            if let firstStep = tl.automaticSteps.first, firstStep.haptic != "none" {
                HapticManager.shared.fire(firstStep.haptic)
            }
        } else {
            // Execute automatic steps
            executeAutomaticSteps(tl.automaticSteps)
        }

        // Register reactive triggers
        registerScreenExitSteps(tl)
        registerActionSteps(tl)
    }

    // MARK: - Automatic Step Execution

    private func executeAutomaticSteps(_ steps: [AnimationStep]) {
        let reduceMotion = isReduceMotionEnabled
        let staggerDelay = reduceMotion ? 0 : (Double(staggerContext.index) * staggerContext.interval)
        let chainDelay = reduceMotion ? 0 : staggerContext.chainDelay
        let priorDelay = reduceMotion ? 0 : staggerContext.priorDelay
        let tlDelay = reduceMotion ? 0 : (timelineDelays[componentId] ?? 0)

        // priorDelay cascades earlier-staggered siblings' enter delays onto this
        // child so a delayed sibling pushes it back instead of being overtaken.
        var cumulativeDelay: TimeInterval = tlDelay + priorDelay + (chainDelay > 0 ? chainDelay + staggerDelay : staggerDelay)

        var previousStepStart: TimeInterval = cumulativeDelay
        var previousStepDuration: TimeInterval = 0

        for step in steps {
            switch step.trigger {
            case .onAppear:
                let startTime = cumulativeDelay
                scheduleStep(step, at: startTime / effectiveSpeed)
                previousStepStart = startTime
                previousStepDuration = totalStepDuration(step)
                cumulativeDelay = startTime + previousStepDuration

            case .afterPrevious(let gap):
                let startTime = cumulativeDelay + gap
                scheduleStep(step, at: startTime / effectiveSpeed)
                previousStepStart = startTime
                previousStepDuration = totalStepDuration(step)
                cumulativeDelay = startTime + previousStepDuration

            case .withPrevious:
                // Start at the same time as the previous step
                let startTime = previousStepStart
                scheduleStep(step, at: startTime / effectiveSpeed)
                // Don't advance cumulativeDelay, but track this step's end for the next afterPrevious
                let thisEnd = startTime + totalStepDuration(step)
                if thisEnd > cumulativeDelay {
                    cumulativeDelay = thisEnd
                }

            default:
                break // Reactive triggers handled separately
            }
        }
    }

    /// Total duration of a step including repeats.
    private func totalStepDuration(_ step: AnimationStep) -> TimeInterval {
        let cycles: Double
        switch step.repeatValue {
        case .finite(let n): cycles = Double(n)
        case .infinite: cycles = 1 // infinite loops don't block the timeline
        }
        return step.duration * cycles
    }

    // MARK: - Schedule a Single Step

    private func scheduleStep(_ step: AnimationStep, at delay: TimeInterval) {
        if delay > 0.001 {
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [step] _ in
                DispatchQueue.main.async {
                    self.runStep(step)
                }
            }
            scheduledTimers.append(timer)
        } else {
            runStep(step)
        }
    }

    /// Runs a step — either a state transition or an effect.
    private func runStep(_ step: AnimationStep) {
        // Fire haptic
        scheduleHaptic(type: step.haptic, timing: step.hapticTiming, delay: 0, duration: step.duration / effectiveSpeed)

        if let effect = step.effect {
            // Named effect — run keyframe animation
            runEffect(effect: effect, duration: step.duration, repeatValue: step.repeatValue)
        } else {
            // State transition
            let targetState = step.to ?? .natural

            let animation = makeAnimation(
                duration: step.duration,
                easing: step.easing,
                springConfig: step.springConfig
            )

            withAnimation(animation) {
                currentOpacity = targetState.opacity
                currentScale = targetState.scale
                currentTranslateX = targetState.translateX
                currentTranslateY = targetState.translateY
                currentRotate = targetState.rotate
            }
        }
    }

    // MARK: - Effect Animation

    private func runEffect(effect: EffectConfig, duration: TimeInterval, repeatValue: RepeatValue) {
        // Stop any existing effect
        stopEffect()

        activeEffect = effect
        effectPhase = 0

        let scaledDuration = duration / effectiveSpeed
        let frameRate: TimeInterval = 1.0 / 60.0
        let totalFrames = scaledDuration / frameRate
        var frameCount: CGFloat = 0
        var currentCycle = 0

        effectTimer = Timer.scheduledTimer(withTimeInterval: frameRate, repeats: true) { t in
            frameCount += 1
            let newPhase = frameCount / CGFloat(totalFrames)

            if newPhase >= 1.0 {
                // Cycle complete
                effectPhase = 0
                frameCount = 0
                currentCycle += 1

                // Check if we should stop
                if case .finite(let maxCycles) = repeatValue, currentCycle >= maxCycles {
                    t.invalidate()
                    effectTimer = nil
                    activeEffect = nil
                    return
                }
            } else {
                effectPhase = newPhase
            }
        }
    }

    private func stopEffect() {
        effectTimer?.invalidate()
        effectTimer = nil
        activeEffect = nil
        effectPhase = 0
    }

    // MARK: - Reactive Step Registration

    private func registerScreenExitSteps(_ tl: AnimationTimeline) {
        let exitSteps = tl.steps(withTrigger: .onScreenExit)
        guard !exitSteps.isEmpty, let lifecycle = screenLifecycle else { return }

        exitCancellable = lifecycle.exitPublisher
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [exitSteps] in
                for step in exitSteps {
                    self.runStep(step)
                }
            }
    }

    private func registerActionSteps(_ tl: AnimationTimeline) {
        actionCancellable = NotificationCenter.default
            .publisher(for: .triggerComponentAnimation)
            .receive(on: DispatchQueue.main)
            .sink { notification in
                guard let targetId = notification.userInfo?["targetComponentId"] as? String,
                      targetId == self.componentId else { return }

                // Check for stepId first (new format)
                if let stepId = notification.userInfo?["stepId"] as? String,
                   let step = tl.step(byId: stepId) {
                    self.runStep(step)
                    return
                }

                // Legacy: check for animation type
                if let animationType = notification.userInfo?["animation"] as? String {
                    switch animationType {
                    case "enter":
                        // Re-run appear steps
                        if let from = tl.from {
                            currentOpacity = from.opacity
                            currentScale = from.scale
                            currentTranslateX = from.translateX
                            currentTranslateY = from.translateY
                            currentRotate = from.rotate
                        }
                        for step in tl.automaticSteps {
                            if case .onAppear = step.trigger {
                                self.runStep(step)
                            }
                        }
                    case "exit":
                        for step in tl.reactiveSteps {
                            if case .onScreenExit = step.trigger {
                                self.runStep(step)
                            } else if case .onAction = step.trigger {
                                self.runStep(step)
                            }
                        }
                    case "attention":
                        for step in tl.steps {
                            if step.effect != nil {
                                self.runStep(step)
                                break
                            }
                        }
                    default:
                        // Try first reactive step
                        if let step = tl.firstOnActionStep() {
                            self.runStep(step)
                        }
                    }
                    return
                }

                // Default: trigger first reactive onAction step
                if let step = tl.firstOnActionStep() {
                    self.runStep(step)
                }
            }
    }

    // MARK: - Animation Building

    private func makeAnimation(duration: TimeInterval, easing: String, springConfig: (response: Double, damping: Double)? = nil) -> Animation {
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
            let config = springConfig ?? (response: 0.35, damping: 0.7)
            animation = .spring(response: config.response * (1.0 / effectiveSpeed), dampingFraction: config.damping)
        default:
            animation = .easeInOut(duration: scaledDuration)
        }

        return animation
    }

    // MARK: - Haptic

    private func scheduleHaptic(type: String, timing: String, delay: TimeInterval, duration: TimeInterval) {
        guard type != "none" else { return }

        switch timing {
        case "end":
            HapticManager.shared.fire(type, after: delay + duration)
        default:
            HapticManager.shared.fire(type, after: delay)
        }
    }

    // MARK: - Helpers

    private func applyNaturalState() {
        currentOpacity = 1
        currentScale = 1
        currentTranslateX = 0
        currentTranslateY = 0
        currentRotate = 0
    }

    private func cleanup() {
        exitCancellable?.cancel()
        exitCancellable = nil
        actionCancellable?.cancel()
        actionCancellable = nil
        stopEffect()
        for timer in scheduledTimers {
            timer.invalidate()
        }
        scheduledTimers.removeAll()
    }

    private var isReduceMotionEnabled: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }
}

// MARK: - Conditional View Modifier

private extension View {
    /// Applies a modifier only when a condition is true; otherwise returns the view unchanged.
    @ViewBuilder
    func ifCondition<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
