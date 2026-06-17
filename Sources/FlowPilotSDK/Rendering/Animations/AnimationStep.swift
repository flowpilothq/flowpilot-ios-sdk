import Foundation

// MARK: - Animation State

/// Transform state for animation — the 5 GPU-friendly animatable properties.
///
/// `nil` values mean "don't change this property" (keep current/natural value).
/// The **natural state** is `{ opacity: 1, scale: 1, translateX: 0, translateY: 0, rotate: 0 }`.
struct AnimationState {
    var opacity: Double
    var scale: Double
    var translateX: Double
    var translateY: Double
    var rotate: Double

    /// The natural (default) state — fully visible, no transforms.
    static let natural = AnimationState(opacity: 1, scale: 1, translateX: 0, translateY: 0, rotate: 0)

    /// Creates a state from a dictionary (e.g., from JSON `from` or `to` fields).
    static func from(dict: [String: Any]?) -> AnimationState {
        guard let dict = dict else { return .natural }
        return AnimationState(
            opacity: asDouble(dict["opacity"]) ?? 1.0,
            scale: asDouble(dict["scale"]) ?? 1.0,
            translateX: asDouble(dict["translateX"]) ?? 0,
            translateY: asDouble(dict["translateY"]) ?? 0,
            rotate: asDouble(dict["rotate"]) ?? 0
        )
    }
}

// MARK: - Step Trigger

/// When an animation step fires.
enum StepTrigger: Equatable {
    // Automatic triggers (part of the timeline sequence)
    case onAppear
    case afterPrevious(gap: TimeInterval) // gap in seconds
    case withPrevious

    // Reactive triggers (wait for external signal)
    case onScreenExit
    case onAction(actionId: String?)
    case onTap
    case onVariable(variable: String)
}

// MARK: - Effect Config

/// Configuration for a named keyframe effect (pulse, shake, etc.).
struct EffectConfig {
    let type: String     // "pulse", "bounce", "shake", "glow", "float", "heartbeat", "wiggle", "flash"
    let intensity: CGFloat // 0-100
}

// MARK: - Repeat Value

/// How many times a step should repeat.
enum RepeatValue: Equatable {
    case finite(Int)
    case infinite

    var isInfinite: Bool {
        if case .infinite = self { return true }
        return false
    }

    var count: Int {
        switch self {
        case .finite(let n): return n
        case .infinite: return -1
        }
    }
}

// MARK: - Animation Step

/// A single animation action in a component's timeline.
struct AnimationStep {
    let id: String
    let name: String?

    // WHEN
    let trigger: StepTrigger

    // WHAT (one of: state transition OR named effect)
    let to: AnimationState?        // Target state. nil = animate to natural state.
    let effect: EffectConfig?      // Named keyframe effect.

    // HOW
    let duration: TimeInterval     // seconds
    let easing: String             // "linear", "ease", "ease-in", "ease-out", "ease-in-out", "spring"
    let springConfig: (response: Double, damping: Double)?

    // REPEAT
    let repeatValue: RepeatValue
    let autoreverse: Bool

    // HAPTIC
    let haptic: String             // "none", "light", "medium", etc.
    let hapticTiming: String       // "start" or "end"

    /// Whether this step is an automatic step (plays as part of the timeline sequence).
    var isAutomatic: Bool {
        switch trigger {
        case .onAppear, .afterPrevious, .withPrevious:
            return true
        default:
            return false
        }
    }

    /// Whether this step is a reactive step (waits for an external signal).
    var isReactive: Bool {
        !isAutomatic
    }
}

// MARK: - Animation Timeline

/// A component's complete animation timeline: initial state + ordered steps.
struct AnimationTimeline {
    /// Initial transform state before any steps run. nil = natural state (visible, no transforms).
    let from: AnimationState?

    /// Ordered list of animation steps.
    let steps: [AnimationStep]

    /// Returns automatic steps only.
    var automaticSteps: [AnimationStep] {
        steps.filter { $0.isAutomatic }
    }

    /// Returns reactive steps only.
    var reactiveSteps: [AnimationStep] {
        steps.filter { $0.isReactive }
    }

    /// Finds the first reactive step matching an onAction trigger.
    func firstOnActionStep() -> AnimationStep? {
        steps.first { step in
            if case .onAction = step.trigger { return true }
            return false
        }
    }

    /// Finds a step by ID.
    func step(byId id: String) -> AnimationStep? {
        steps.first { $0.id == id }
    }

    /// Finds all steps matching a specific trigger type.
    func steps(withTrigger triggerType: StepTrigger) -> [AnimationStep] {
        steps.filter { $0.trigger == triggerType }
    }
}

// MARK: - Timeline Resolution

extension AnimationTimeline {

    /// Resolves an `AnimationTimeline` from component props.
    ///
    /// Tries the new `animations` prop first, then falls back to legacy
    /// `animation` + `exitAnimation` + `attention` props via `LegacyAnimationCompat`.
    ///
    /// - Parameters:
    ///   - props: The component's props, or `nil`.
    ///   - variableStore: The current variable store for resolving conditional values.
    /// - Returns: A resolved timeline, or `nil` if no animations are configured.
    static func resolve(from props: ComponentProps?, variableStore: VariableStore) -> AnimationTimeline? {
        guard let props = props else { return nil }

        // 1. Try new `animations` prop first
        if let raw = props.getRaw("animations") {
            if let timeline = parseAnimationsProperty(raw) {
                return timeline
            }
        }

        // 2. Fall back to legacy props
        return LegacyAnimationCompat.convertToTimeline(props: props, variableStore: variableStore)
    }

    /// Parses the new `animations` property format.
    ///
    /// Expected shape:
    /// ```json
    /// {
    ///   "from": { "opacity": 0, "translateY": 20 },
    ///   "steps": [
    ///     { "id": "appear", "trigger": { "type": "onAppear" }, "duration": 300, ... }
    ///   ]
    /// }
    /// ```
    private static func parseAnimationsProperty(_ raw: Any) -> AnimationTimeline? {
        var animationsDict: [String: Any]?

        if let dict = raw as? [String: Any] {
            if let typeStr = dict["type"] as? String, typeStr == "static",
               let innerValue = dict["value"] as? [String: Any] {
                // PropertyValue wrapper
                animationsDict = innerValue
            } else if dict["steps"] != nil {
                // Raw animations config dict
                animationsDict = dict
            }
        }

        guard let dict = animationsDict,
              let stepsArray = dict["steps"] as? [[String: Any]],
              !stepsArray.isEmpty else {
            return nil
        }

        let from = AnimationState.from(dict: dict["from"] as? [String: Any])
        let isFromNatural = (dict["from"] as? [String: Any]) == nil

        var steps: [AnimationStep] = []
        for stepDict in stepsArray {
            if let step = parseStep(stepDict) {
                steps.append(step)
            }
        }

        guard !steps.isEmpty else { return nil }

        return AnimationTimeline(
            from: isFromNatural ? nil : from,
            steps: steps
        )
    }

    /// Parses a single step dictionary.
    static func parseStep(_ dict: [String: Any]) -> AnimationStep? {
        let id = dict["id"] as? String ?? UUID().uuidString
        let name = dict["name"] as? String

        // Parse trigger
        let trigger = parseTrigger(dict["trigger"])

        // Parse target state (if present)
        let to: AnimationState?
        if let toDict = dict["to"] as? [String: Any] {
            to = AnimationState.from(dict: toDict)
        } else {
            to = nil // animate to natural state
        }

        // Parse effect (if present)
        let effect: EffectConfig?
        if let effectDict = dict["effect"] as? [String: Any] {
            let effectType = effectDict["type"] as? String ?? "pulse"
            let intensity = CGFloat(asDouble(effectDict["intensity"]) ?? 50)
            effect = EffectConfig(type: effectType, intensity: intensity)
        } else {
            effect = nil
        }

        // Duration (ms → seconds)
        let duration = (asDouble(dict["duration"]) ?? 300) / 1000

        // Easing
        let easing = dict["easing"] as? String ?? "ease"

        // Spring config
        let springConfig: (response: Double, damping: Double)?
        if let springDict = dict["springConfig"] as? [String: Any] {
            springConfig = (
                response: asDouble(springDict["response"]) ?? 0.35,
                damping: asDouble(springDict["damping"]) ?? 0.7
            )
        } else {
            springConfig = nil
        }

        // Repeat
        let repeatValue: RepeatValue
        if let repeatStr = dict["repeat"] as? String, repeatStr == "infinite" {
            repeatValue = .infinite
        } else if let repeatNum = dict["repeat"] as? Int {
            repeatValue = .finite(max(1, repeatNum))
        } else {
            repeatValue = .finite(1)
        }

        let autoreverse = dict["autoreverse"] as? Bool ?? false

        // Haptic
        let haptic = dict["haptic"] as? String ?? "none"
        let hapticTiming = dict["hapticTiming"] as? String ?? "start"

        return AnimationStep(
            id: id,
            name: name,
            trigger: trigger,
            to: to,
            effect: effect,
            duration: duration,
            easing: easing,
            springConfig: springConfig,
            repeatValue: repeatValue,
            autoreverse: autoreverse,
            haptic: haptic,
            hapticTiming: hapticTiming
        )
    }

    /// Parses a trigger from its dict representation.
    private static func parseTrigger(_ raw: Any?) -> StepTrigger {
        guard let triggerDict = raw as? [String: Any],
              let type = triggerDict["type"] as? String else {
            return .onAppear
        }

        switch type {
        case "onAppear":
            return .onAppear
        case "afterPrevious":
            let gapMs = asDouble(triggerDict["gap"]) ?? 0
            return .afterPrevious(gap: gapMs / 1000)
        case "withPrevious":
            return .withPrevious
        case "onScreenExit":
            return .onScreenExit
        case "onAction":
            let actionId = triggerDict["actionId"] as? String
            return .onAction(actionId: actionId)
        case "onTap":
            return .onTap
        case "onVariable":
            let variable = triggerDict["variable"] as? String ?? ""
            return .onVariable(variable: variable)
        default:
            return .onAppear
        }
    }
}

// MARK: - Helpers

/// Safely coerces a value to `Double`, handling both `Int` and `Double` JSON types.
func asDouble(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    return nil
}
