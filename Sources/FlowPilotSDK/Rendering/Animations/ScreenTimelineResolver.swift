import Foundation

// MARK: - Screen Timeline Resolver

/// Resolves a screen-level timeline into absolute start delays for each component.
///
/// Components define HOW they animate (steps). The timeline defines WHEN they start.
/// This resolver computes the delay (in seconds) that each component's `onAppear`
/// step should wait before firing.
enum ScreenTimelineResolver {

    /// Resolves all timeline events into a dictionary of componentId → delay (seconds).
    /// Only `startTimeline` events contribute delays; other action types are ignored.
    static func computeTimelineDelays(
        screen: ScreenNode,
        animationSpeed: Double = 1.0
    ) -> [String: TimeInterval] {
        guard let events = screen.timeline, !events.isEmpty else { return [:] }

        let speedFactor = max(0.25, min(2.0, animationSpeed))
        var delays: [String: TimeInterval] = [:]
        var eventStartTimes: [String: TimeInterval] = [:]
        var eventDurations: [String: TimeInterval] = [:]

        for event in events {
            let startTime: TimeInterval

            if let at = event.at {
                startTime = (at / 1000.0) / speedFactor
            } else if let afterId = event.after {
                let refStart = eventStartTimes[afterId] ?? 0
                let refDuration = eventDurations[afterId] ?? 0
                let gap = ((event.afterGap ?? 0) / 1000.0) / speedFactor
                startTime = refStart + refDuration + gap
            } else {
                startTime = 0
            }

            eventStartTimes[event.id] = startTime

            // Compute target component's animation duration
            var duration: TimeInterval = 0
            if let layout = screen.layout {
                if let targetComponent = findComponentById(in: layout, id: event.target) {
                    duration = computeComponentDuration(
                        component: targetComponent,
                        animationSpeed: speedFactor
                    )
                }
            }
            eventDurations[event.id] = duration

            // Only startTimeline events produce a delay for the component
            if case .startTimeline = event.resolvedAction {
                delays[event.target] = startTime
            }
        }

        return delays
    }

    // MARK: - Particle Timeline Events

    /// A scheduled particle event resolved from the screen timeline.
    struct ScheduledParticleEvent {
        let delay: TimeInterval        // seconds from screen appear
        let config: [String: Any]      // dictionary for ParticleEffectConfig.from(dict:)
    }

    /// Resolves all particle timeline events into scheduled events with absolute delays.
    static func computeParticleEvents(
        screen: ScreenNode,
        animationSpeed: Double = 1.0
    ) -> [ScheduledParticleEvent] {
        guard let events = screen.timeline, !events.isEmpty else { return [] }

        let speedFactor = max(0.25, min(2.0, animationSpeed))
        var eventStartTimes: [String: TimeInterval] = [:]
        var eventDurations: [String: TimeInterval] = [:]
        var particleEvents: [ScheduledParticleEvent] = []

        for event in events {
            let startTime: TimeInterval

            if let at = event.at {
                startTime = (at / 1000.0) / speedFactor
            } else if let afterId = event.after {
                let refStart = eventStartTimes[afterId] ?? 0
                let refDuration = eventDurations[afterId] ?? 0
                let gap = ((event.afterGap ?? 0) / 1000.0) / speedFactor
                startTime = refStart + refDuration + gap
            } else {
                startTime = 0
            }

            eventStartTimes[event.id] = startTime

            // Compute duration for sequencing
            if let layout = screen.layout,
               let targetComponent = findComponentById(in: layout, id: event.target) {
                eventDurations[event.id] = computeComponentDuration(
                    component: targetComponent,
                    animationSpeed: speedFactor
                )
            }

            // Collect particle events
            if case .particle(let effect, let duration, let colors, let emoji,
                              let density, let size, let direction,
                              let spread, let gravity, let speed, let haptic) = event.resolvedAction {
                var dict: [String: Any] = ["effect": effect]
                if let duration = duration { dict["duration"] = duration }
                if let colors = colors { dict["colors"] = colors }
                if let emoji = emoji { dict["emoji"] = emoji }
                if let density = density { dict["density"] = density }
                if let size = size { dict["size"] = size }
                if let direction = direction { dict["direction"] = direction }
                if let spread = spread { dict["spread"] = spread }
                if let gravity = gravity { dict["gravity"] = gravity }
                if let speed = speed { dict["speed"] = speed }
                if let haptic = haptic { dict["haptic"] = haptic }

                particleEvents.append(ScheduledParticleEvent(
                    delay: startTime,
                    config: dict
                ))
            }
        }

        return particleEvents
    }

    // MARK: - Component Duration Computation

    /// Computes the total automatic animation duration for a component (in seconds).
    private static func computeComponentDuration(
        component: ComponentNode,
        animationSpeed: Double
    ) -> TimeInterval {
        // Check for text effects (typewriter duration depends on content)
        if let textEffectDuration = estimateTextEffectDuration(component: component, speedFactor: animationSpeed) {
            return textEffectDuration
        }

        // Check for stagger on containers
        if let stagger = resolveStaggerForDuration(component: component),
           stagger.enabled,
           let children = component.children, !children.isEmpty {
            return computeStaggerDuration(
                component: component,
                staggerInterval: stagger.interval,
                animationSpeed: animationSpeed
            )
        }

        // Check for step-based timeline
        if let raw = component.props?.getRaw("animations") {
            if let timeline = AnimationTimeline.parseAnimationsPropertyForDuration(raw) {
                return computeStepsDuration(steps: timeline.steps, speedFactor: animationSpeed)
            }
        }

        // Legacy: check for animation prop duration
        if let raw = component.props?.getRaw("animation") {
            let durationMs = extractDurationFromAnimationProp(raw)
            if durationMs > 0 {
                return (durationMs / 1000.0) / animationSpeed
            }
        }

        return 0
    }

    /// Computes total duration of automatic animation steps (in seconds).
    private static func computeStepsDuration(steps: [AnimationStep], speedFactor: Double) -> TimeInterval {
        var totalEnd: TimeInterval = 0
        var lastStepEnd: TimeInterval = 0

        for step in steps {
            switch step.trigger {
            case .onAppear:
                let dur = effectiveStepDuration(step, speedFactor: speedFactor)
                lastStepEnd = dur
                totalEnd = max(totalEnd, dur)

            case .afterPrevious(let gap):
                let scaledGap = gap / speedFactor
                let dur = effectiveStepDuration(step, speedFactor: speedFactor)
                totalEnd = lastStepEnd + scaledGap + dur
                lastStepEnd = totalEnd

            case .withPrevious:
                let dur = effectiveStepDuration(step, speedFactor: speedFactor)
                let parallelEnd = lastStepEnd + dur
                totalEnd = max(totalEnd, parallelEnd)
                // Don't advance lastStepEnd — parallel step

            default:
                break // Reactive triggers don't contribute
            }
        }

        return totalEnd
    }

    /// Duration of a single step accounting for repeats (in seconds).
    private static func effectiveStepDuration(_ step: AnimationStep, speedFactor: Double) -> TimeInterval {
        let baseDuration = step.duration / speedFactor
        let cycles: Double
        switch step.repeatValue {
        case .finite(let n): cycles = Double(n)
        case .infinite: cycles = 1 // infinite loops don't block timeline
        }
        return baseDuration * cycles
    }

    // MARK: - Stagger Duration

    /// Computes stagger duration: (childCount - 1) * interval + longestChildDuration.
    private static func computeStaggerDuration(
        component: ComponentNode,
        staggerInterval: TimeInterval,
        animationSpeed: Double
    ) -> TimeInterval {
        guard let children = component.children, !children.isEmpty else { return 0 }

        let scaledInterval = staggerInterval / animationSpeed
        var longestChildDuration: TimeInterval = 0

        for child in children {
            let dur = computeComponentDuration(component: child, animationSpeed: animationSpeed)
            longestChildDuration = max(longestChildDuration, dur)
        }

        return Double(children.count - 1) * scaledInterval + longestChildDuration
    }

    /// Lightweight stagger config check for duration computation.
    private static func resolveStaggerForDuration(component: ComponentNode) -> (enabled: Bool, interval: TimeInterval)? {
        guard let props = component.props else { return nil }

        if let raw = props.getRaw("stagger") {
            var staggerDict: [String: Any]?
            if let dict = raw as? [String: Any] {
                if let typeStr = dict["type"] as? String, typeStr == "static",
                   let innerValue = dict["value"] as? [String: Any] {
                    staggerDict = innerValue
                } else if dict["enabled"] != nil {
                    staggerDict = dict
                }
            }
            if let sDict = staggerDict {
                let enabled = sDict["enabled"] as? Bool ?? false
                let intervalMs = asDouble(sDict["interval"]) ?? 80
                return (enabled: enabled, interval: intervalMs / 1000.0)
            }
        }

        return nil
    }

    // MARK: - Text Effect Duration

    /// Estimates the duration of a text effect based on content and speed.
    private static func estimateTextEffectDuration(component: ComponentNode, speedFactor: Double) -> TimeInterval? {
        guard let props = component.props else { return nil }

        // Check for textEffect prop
        guard let raw = props.getRaw("textEffect") else { return nil }

        var effectDict: [String: Any]?
        if let dict = raw as? [String: Any] {
            if let typeStr = dict["type"] as? String, typeStr == "static",
               let innerValue = dict["value"] as? [String: Any] {
                effectDict = innerValue
            } else if dict["type"] != nil {
                effectDict = dict
            }
        }

        guard let eDict = effectDict,
              let type = eDict["type"] as? String,
              type != "none" else { return nil }

        let text = extractTextContent(from: props)
        let delay = (asDouble(eDict["delay"]) ?? 0) / 1000.0 / speedFactor

        switch type {
        case "typewriter":
            let speed = asDouble(eDict["speed"]) ?? 40 // chars per second
            guard speed > 0 else { return nil }
            return delay + (Double(text.count) / speed) / speedFactor

        case "typewriterWord":
            let speed = asDouble(eDict["speed"]) ?? 8 // words per second
            guard speed > 0 else { return nil }
            let wordCount = Double(text.split(separator: " ").count)
            return delay + (wordCount / speed) / speedFactor

        case "countUp":
            let durationMs = asDouble(eDict["duration"]) ?? 2000
            return delay + (durationMs / 1000.0) / speedFactor

        case "fadePerLine":
            let lines = Double(text.split(separator: "\n").count)
            let intervalMs = asDouble(eDict["duration"]) ?? 250
            return delay + (lines * intervalMs / 1000.0) / speedFactor

        case "scramble":
            let speed = asDouble(eDict["speed"]) ?? 40
            guard speed > 0 else { return nil }
            return delay + (Double(text.count) / speed) / speedFactor

        default:
            return nil
        }
    }

    /// Extracts text content from a component for duration estimation.
    private static func extractTextContent(from props: ComponentProps) -> String {
        // Try static text values
        if let raw = props.getRaw("text") {
            if let str = raw as? String { return str }
            if let dict = raw as? [String: Any] {
                if let typeStr = dict["type"] as? String, typeStr == "static",
                   let value = dict["value"] as? String {
                    return value
                }
            }
        }
        if let raw = props.getRaw("label") {
            if let str = raw as? String { return str }
            if let dict = raw as? [String: Any],
               let typeStr = dict["type"] as? String, typeStr == "static",
               let value = dict["value"] as? String {
                return value
            }
        }
        return ""
    }

    // MARK: - Legacy Animation Duration

    /// Extracts duration from a legacy animation prop (in ms).
    private static func extractDurationFromAnimationProp(_ raw: Any) -> Double {
        var animDict: [String: Any]?
        if let dict = raw as? [String: Any] {
            if let typeStr = dict["type"] as? String, typeStr == "static",
               let innerValue = dict["value"] as? [String: Any] {
                animDict = innerValue
            } else if dict["duration"] != nil || dict["trigger"] != nil {
                animDict = dict
            }
        }
        guard let aDict = animDict else { return 0 }
        return asDouble(aDict["duration"]) ?? 300
    }

    // MARK: - Tree Traversal

    /// Recursively finds a component by ID in the component tree.
    private static func findComponentById(in node: ComponentNode, id: String) -> ComponentNode? {
        if node.id == id { return node }
        if let children = node.children {
            for child in children {
                if let found = findComponentById(in: child, id: id) {
                    return found
                }
            }
        }
        return nil
    }
}

// MARK: - AnimationTimeline duration-only parsing

extension AnimationTimeline {
    /// Parses just enough of the animations property to extract steps for duration computation.
    /// This is a lightweight parse used by the timeline resolver — it reuses the same logic
    /// as the full parser but is called from a non-ViewModifier context.
    static func parseAnimationsPropertyForDuration(_ raw: Any) -> AnimationTimeline? {
        // Reuse the main parser — it's already lightweight
        var animationsDict: [String: Any]?
        if let dict = raw as? [String: Any] {
            if let typeStr = dict["type"] as? String, typeStr == "static",
               let innerValue = dict["value"] as? [String: Any] {
                animationsDict = innerValue
            } else if dict["steps"] != nil {
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
}
