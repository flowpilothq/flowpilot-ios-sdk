import Foundation

// MARK: - Legacy Animation Compatibility

/// Converts old-format animation props (`animation`, `exitAnimation`, `attention`)
/// to the new unified step-based `AnimationTimeline` model.
///
/// This provides backward compatibility so flows created with the old schema
/// continue to work without modification. The conversion happens at parse time —
/// the rest of the animation engine only sees `AnimationTimeline`.
///
/// Fallback chain:
/// 1. New `animations` prop → used directly (handled by `AnimationTimeline.resolve`)
/// 2. Old `animation` + `exitAnimation` + `attention` props → converted here
/// 3. Legacy flat props (`animateOn`, `animOpacity`, etc.) → converted here
struct LegacyAnimationCompat {

    /// Converts old-format props to a unified `AnimationTimeline`.
    ///
    /// Tries the old grouped `animation` object first, then falls back to
    /// legacy flat props. Also reads `exitAnimation` and `attention` and
    /// merges them into the step list.
    ///
    /// - Parameters:
    ///   - props: The component's props.
    ///   - variableStore: The current variable store for resolving conditional values.
    /// - Returns: A timeline, or `nil` if no legacy animation props are found.
    static func convertToTimeline(props: ComponentProps, variableStore: VariableStore) -> AnimationTimeline? {
        var steps: [AnimationStep] = []
        var from: AnimationState? = nil

        // 1. Try old `animation` prop (grouped or flat)
        if let enterConfig = AnimationConfig.resolve(from: props, variableStore: variableStore),
           enterConfig.trigger == "appear" {
            from = AnimationState(
                opacity: enterConfig.fromOpacity,
                scale: enterConfig.fromScale,
                translateX: enterConfig.fromTranslateX,
                translateY: enterConfig.fromTranslateY,
                rotate: enterConfig.fromRotate
            )

            steps.append(AnimationStep(
                id: "legacy-appear",
                name: "Fade In",
                trigger: .onAppear,
                to: nil, // animate to natural state
                effect: nil,
                duration: enterConfig.duration,
                easing: enterConfig.easing,
                springConfig: nil,
                repeatValue: .finite(1),
                autoreverse: false,
                haptic: enterConfig.haptic,
                hapticTiming: enterConfig.hapticTiming
            ))
        }

        // 2. Try old `attention` prop
        if let attentionConfig = AttentionConfig.resolve(from: props) {
            let trigger: StepTrigger
            if steps.isEmpty {
                trigger = .onAppear
            } else {
                trigger = .afterPrevious(gap: attentionConfig.delay)
            }

            steps.append(AnimationStep(
                id: "legacy-attention",
                name: attentionConfig.effect.capitalized,
                trigger: trigger,
                to: nil,
                effect: EffectConfig(type: attentionConfig.effect, intensity: attentionConfig.intensity),
                duration: attentionConfig.duration,
                easing: "ease-in-out",
                springConfig: nil,
                repeatValue: attentionConfig.repeatCount == -1 ? .infinite : .finite(attentionConfig.repeatCount),
                autoreverse: false,
                haptic: "none",
                hapticTiming: "start"
            ))
        }

        // 3. Try old `exitAnimation` prop
        if let exitConfig = ExitAnimationConfig.resolve(from: props, variableStore: variableStore) {
            let trigger: StepTrigger
            switch exitConfig.trigger {
            case "screenExit":
                trigger = .onScreenExit
            case "manual":
                trigger = .onAction(actionId: nil)
            default:
                trigger = .onScreenExit
            }

            let toState = AnimationState(
                opacity: exitConfig.toOpacity,
                scale: exitConfig.toScale,
                translateX: exitConfig.toTranslateX,
                translateY: exitConfig.toTranslateY,
                rotate: exitConfig.toRotate
            )

            steps.append(AnimationStep(
                id: "legacy-exit",
                name: "Exit",
                trigger: trigger,
                to: toState,
                effect: nil,
                duration: exitConfig.duration,
                easing: exitConfig.easing,
                springConfig: nil,
                repeatValue: .finite(1),
                autoreverse: false,
                haptic: exitConfig.haptic,
                hapticTiming: "start"
            ))
        }

        guard !steps.isEmpty else { return nil }
        return AnimationTimeline(from: from, steps: steps)
    }
}
