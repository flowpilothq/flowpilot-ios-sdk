import SwiftUI

// MARK: - Progress Bar View

/// Renders a progress bar component.
///
/// When the node carries an `autoProgress` timeline (the SAME config the ring
/// uses), the bar drives ITSELF: it eases through staged targets, pausing at
/// each, with a live percent CENTERED OVER the bar and a per-stage caption below
/// — the horizontal "analysis loader" (`AutoProgressBar`). Mirrors the dashboard
/// canvas + Expo. See the `loader-bar` certified block.
struct ProgressBarView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    var renderTrigger: Int = 0

    private var props: ComponentProps? { node.props }
    private var navigationController: NavigationController { actionContext.navigationController }

    var body: some View {
        // Force re-evaluation when renderTrigger changes
        let _ = renderTrigger
        if let auto = props?.ringAutoProgress {
            AutoProgressBar(
                config: auto,
                height: resolvedHeight,
                cornerRadius: resolvedCornerRadius,
                color: resolvedColor,
                trackColor: resolvedTrackColor,
                percentFontSize: percentFontSize,
                percentColor: percentColor,
                percentWeight: percentWeight,
                captionFontSize: captionFontSize,
                captionColor: captionColor,
                captionWeight: captionWeight,
                captionSpacing: captionSpacing,
                onComplete: fireOnComplete
            )
        } else {
            AnimatedProgressTrack(
                height: resolvedHeight,
                trackColor: resolvedTrackColor,
                fillColor: resolvedColor,
                progress: resolvedProgress,
                cornerRadius: resolvedCornerRadius,
                animateProgress: resolvedAnimateProgress,
                animationDuration: resolvedAnimationDuration,
                animationCurve: resolvedAnimationCurve
            )
        }
    }

    // MARK: autoProgress label styling (shared raw keys with ringProgress)

    private var percentFontSize: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.percentFontSize, store: variableStore, default: 16.0))
    }
    private var percentColor: Color {
        Color(hex: PropertyResolver.resolve(props?.percentColor, store: variableStore, default: "#111827")) ?? .primary
    }
    private var percentWeight: Font.Weight {
        progressFontWeight(from: PropertyResolver.resolve(props?.percentFontWeight, store: variableStore, default: "700"))
    }
    private var captionFontSize: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.captionFontSize, store: variableStore, default: 15.0))
    }
    private var captionColor: Color {
        Color(hex: PropertyResolver.resolve(props?.captionColor, store: variableStore, default: "#111827")) ?? .primary
    }
    private var captionWeight: Font.Weight {
        progressFontWeight(from: PropertyResolver.resolve(props?.captionFontWeight, store: variableStore, default: "600"))
    }
    private var captionSpacing: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.captionSpacing, store: variableStore, default: 16.0))
    }

    /// Fire the loader's `onComplete` actions (e.g. `goNext`) when the timeline
    /// finishes — same path a button tap uses, on its own Task.
    private func fireOnComplete() {
        guard let actions = props?.ringAutoProgress?.onComplete, !actions.isEmpty else { return }
        let scheduled = actions.map { ScheduledAction(action: $0) }
        Task {
            await actionExecutor.execute(
                actions: scheduled,
                context: actionContext,
                elementId: node.id,
                elementType: node.type.rawValue
            )
        }
    }

    private var resolvedProgress: Double {
        let mode = PropertyResolver.resolve(props?.mode, store: variableStore, default: "custom")

        if mode == "auto" {
            // Use NavigationController to calculate progress based on current screen position
            return navigationController.calculateProgress()
        } else {
            let value = PropertyResolver.resolve(props?.progressValue, store: variableStore, default: 50.0)
            return max(0, min(100, value))
        }
    }

    private var resolvedColor: Color {
        let colorStr = PropertyResolver.resolve(props?.color, store: variableStore, default: "#4F46E5")
        return Color(hex: colorStr) ?? .blue
    }

    private var resolvedTrackColor: Color {
        let colorStr = PropertyResolver.resolve(props?.trackColor, store: variableStore, default: "#e5e7eb")
        return Color(hex: colorStr) ?? Color(red: 0.9, green: 0.9, blue: 0.92)
    }

    private var resolvedHeight: CGFloat {
        if let height = props?.height, case .fixed(let value) = height {
            return CGFloat(value)
        }
        return 8
    }

    private var resolvedCornerRadius: CGFloat? {
        // "auto" means use capsule (nil), otherwise use the specified value
        if let radius = props?.cornerRadius {
            return CGFloat(PropertyResolver.resolve(radius, store: variableStore, default: 0.0))
        }
        return nil // nil = auto/capsule
    }

    private var resolvedAnimateProgress: Bool {
        PropertyResolver.resolve(props?.animateProgress, store: variableStore, default: false)
    }

    private var resolvedAnimationDuration: Double {
        PropertyResolver.resolve(props?.animationDuration, store: variableStore, default: 300.0)
    }

    private var resolvedAnimationCurve: String {
        PropertyResolver.resolve(props?.animationCurve, store: variableStore, default: "ease")
    }
}

/// Animated progress track with configurable animation
private struct AnimatedProgressTrack: View {
    let height: CGFloat
    let trackColor: Color
    let fillColor: Color
    let progress: Double
    let cornerRadius: CGFloat?
    let animateProgress: Bool
    let animationDuration: Double
    let animationCurve: String

    @State private var animatedProgress: Double = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track background
                trackView(color: trackColor, width: geometry.size.width)

                // Progress fill
                trackView(color: fillColor, width: max(0, geometry.size.width * animatedProgress / 100.0))
            }
        }
        .frame(height: height)
        .clipped()
        .onAppear {
            updateProgress(to: progress, animated: false)
        }
        .onChange(of: progress) { newValue in
            updateProgress(to: newValue, animated: animateProgress)
        }
    }

    @ViewBuilder
    private func trackView(color: Color, width: CGFloat) -> some View {
        if let radius = cornerRadius, radius > 0 {
            RoundedRectangle(cornerRadius: radius)
                .fill(color)
                .frame(width: width, height: height)
        } else {
            Capsule()
                .fill(color)
                .frame(width: width, height: height)
        }
    }

    private func updateProgress(to newValue: Double, animated: Bool) {
        if animated {
            withAnimation(resolvedAnimation) {
                animatedProgress = newValue
            }
        } else {
            animatedProgress = newValue
        }
    }

    private var resolvedAnimation: Animation {
        let duration = animationDuration / 1000.0 // Convert ms to seconds

        switch animationCurve {
        case "linear":
            return .linear(duration: duration)
        case "ease-in":
            return .easeIn(duration: duration)
        case "ease-out":
            return .easeOut(duration: duration)
        case "ease-in-out":
            return .easeInOut(duration: duration)
        case "ease":
            return .easeInOut(duration: duration)
        default:
            return .easeInOut(duration: duration)
        }
    }
}

// MARK: - Auto Progress Bar (self-driving analysis loader, horizontal)

/// The horizontal counterpart to `AutoProgressRing`: a self-driving linear loader
/// that eases through staged targets over a timeline, pausing at each, with a
/// live percent centered OVER the bar and a per-stage caption below. Reuses the
/// shared `RingAutoProgress` config + schedule math (mirrors the dashboard + Expo).
private struct AutoProgressBar: View {
    let config: RingAutoProgress
    let height: CGFloat
    /// nil = capsule (pill), otherwise a rounded rectangle radius.
    let cornerRadius: CGFloat?
    let color: Color
    let trackColor: Color
    let percentFontSize: CGFloat
    let percentColor: Color
    let percentWeight: Font.Weight
    let captionFontSize: CGFloat
    let captionColor: Color
    let captionWeight: Font.Weight
    let captionSpacing: CGFloat
    let onComplete: () -> Void

    @State private var start = Date()
    @State private var completeWork: DispatchWorkItem?
    @State private var hapticWork: [DispatchWorkItem] = []

    private var schedule: ProgressAutoSchedule { buildProgressAutoSchedule(config.stages) }
    private var hasCaption: Bool { config.stages.contains { !($0.caption ?? "").isEmpty } }

    /// A capsule is just a rounded rect with radius = height/2 — collapse both to
    /// one `RoundedRectangle` (AnyShape is iOS 16+, the SDK targets iOS 15+).
    private var effectiveCornerRadius: CGFloat {
        if let radius = cornerRadius, radius > 0 { return radius }
        return height / 2
    }

    var body: some View {
        let schedule = self.schedule
        let r = effectiveCornerRadius
        // One TimelineView drives the fill, the centered percent, and the caption
        // from a single sample so they never drift.
        TimelineView(.animation) { ctx in
            let elapsedMs = ctx.date.timeIntervalSince(start) * 1000
            let sample = sampleProgressAuto(schedule, easing: config.easing, elapsedMs: elapsedMs, loop: config.loop)
            VStack(spacing: 0) {
                // Track + fill, clipped to the pill. The percent is an OVERLAY on
                // top (NOT a ZStack child inside the GeometryReader, which would
                // pin it top-leading and let the clip cut it off) so it is always
                // centered over the full bar and never clipped. Mirrors the
                // dashboard's absolutely-centered percent + Expo's centered Text.
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: r).fill(trackColor)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: r)
                            .fill(color)
                            .frame(width: max(0, geo.size.width * CGFloat(sample.value)))
                    }
                }
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: r))
                .overlay(percentLabel(sample))

                if hasCaption {
                    Text(sample.caption ?? "")
                        .font(.system(size: captionFontSize, weight: captionWeight))
                        .foregroundColor(captionColor)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, captionSpacing)
                }
            }
        }
        .onAppear {
            start = Date()
            scheduleComplete()
            scheduleHaptics()
        }
        .onDisappear {
            completeWork?.cancel()
            hapticWork.forEach { $0.cancel() }
        }
    }

    /// The live percent, centered over the bar (the overlay's default alignment).
    @ViewBuilder
    private func percentLabel(_ sample: (value: Double, caption: String?)) -> some View {
        if config.showPercent {
            Text("\(Int((sample.value * 100).rounded()))\(config.percentSuffix)")
                .font(.system(size: percentFontSize, weight: percentWeight))
                .foregroundColor(percentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private func scheduleComplete() {
        completeWork?.cancel()
        guard !config.loop, !config.onComplete.isEmpty else { return }
        let totalSec = schedule.total / 1000.0
        let work = DispatchWorkItem { onComplete() }
        completeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, totalSec), execute: work)
    }

    /// Fire one haptic each time the bar reaches a stage's target (the start of
    /// every hold segment). Tracked so navigating away cancels pending ticks.
    private func scheduleHaptics() {
        hapticWork.forEach { $0.cancel() }
        hapticWork = []
        guard config.haptic else { return }
        let times = schedule.segments.filter { $0.hold }.map { $0.start }
        var works: [DispatchWorkItem] = []
        for ms in times {
            let work = DispatchWorkItem { HapticManager.shared.fire(config.hapticIntensity) }
            works.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ms / 1000.0), execute: work)
        }
        hapticWork = works
    }
}

// MARK: - Auto Progress schedule math (mirrors dashboard + Expo + ring)

private struct ProgressAutoSegment {
    let start: Double
    let end: Double
    let from: Double
    let to: Double
    let caption: String?
    let hold: Bool
}

private struct ProgressAutoSchedule {
    let segments: [ProgressAutoSegment]
    let total: Double
    let finalValue: Double
}

private func buildProgressAutoSchedule(_ stages: [RingAutoProgressStage]) -> ProgressAutoSchedule {
    var segments: [ProgressAutoSegment] = []
    var t = 0.0
    var prev = 0.0
    for stage in stages {
        let target = max(0, min(1, stage.target))
        let ramp = max(0, stage.rampMs)
        let hold = max(0, stage.holdMs)
        if ramp > 0 {
            segments.append(ProgressAutoSegment(start: t, end: t + ramp, from: prev, to: target, caption: stage.caption, hold: false))
            t += ramp
        }
        segments.append(ProgressAutoSegment(start: t, end: t + hold, from: target, to: target, caption: stage.caption, hold: true))
        t += hold
        prev = target
    }
    return ProgressAutoSchedule(segments: segments, total: t, finalValue: prev)
}

private func progressEase(_ curve: String, _ t: Double) -> Double {
    let x = max(0, min(1, t))
    switch curve {
    case "linear": return x
    case "ease-in": return x * x
    case "ease-out": return 1 - (1 - x) * (1 - x)
    default: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}

private func sampleProgressAuto(
    _ schedule: ProgressAutoSchedule,
    easing: String,
    elapsedMs: Double,
    loop: Bool
) -> (value: Double, caption: String?) {
    guard let last = schedule.segments.last else { return (0, nil) }
    var e = max(0, elapsedMs)
    if loop && schedule.total > 0 {
        e = e.truncatingRemainder(dividingBy: schedule.total)
    }
    if e >= schedule.total {
        return (schedule.finalValue, last.caption)
    }
    for seg in schedule.segments {
        if e < seg.end {
            if seg.hold || seg.end == seg.start {
                return (seg.to, seg.caption)
            }
            let local = (e - seg.start) / (seg.end - seg.start)
            return (seg.from + (seg.to - seg.from) * progressEase(easing, local), seg.caption)
        }
    }
    return (schedule.finalValue, last.caption)
}

private func progressFontWeight(from raw: String) -> Font.Weight {
    switch raw {
    case "100", "200", "300": return .light
    case "400", "normal", "regular": return .regular
    case "500": return .medium
    case "600": return .semibold
    case "700", "bold": return .bold
    case "800", "900": return .heavy
    default: return .regular
    }
}

// MARK: - Custom Component View

/// Renders custom components registered with FlowPilot
/// Custom components are "dumb renderers" - they emit intent, FlowPilot decides what to do
///
/// **Key Principles**:
/// 1. SDK resolves by **key + version** (not just componentType)
/// 2. SDK does NOT know about editor IDs or navigation
/// 3. SDK only: receives inputs, emits events
/// 4. Components are black-box renderers
struct CustomComponentView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext

    var body: some View {
        // Get component key and version from props
        // Supports both new format (customComponent.key) and legacy (componentType)
        let componentKey = node.props?.resolvedComponentKey ?? "unknown"
        let componentVersion = node.props?.resolvedComponentVersion ?? 1

        // Look up by key + version
        if let definition = FlowPilot.shared?.getCustomComponent(key: componentKey, version: componentVersion) {
            // Resolve all inputs (unified model)
            let resolvedInputs = resolveInputs(node.props?.componentInputs, definition: definition)

            // Create props with resolved inputs
            let props = CustomComponentProps(inputs: resolvedInputs)

            // Create context with emit handler that routes to interaction system
            let context = CustomComponentContext(
                componentType: componentKey,
                containerSize: CGSize(width: 300, height: 200), // TODO: Get actual size from GeometryReader
                containerConstraints: .init(),
                outputSchemas: definition.outputs,
                emitHandler: { [actionExecutor, actionContext, node] eventName, payload in
                    // Route emitted events through the interaction system
                    // This allows the editor to define what actions happen
                    handleEmittedEvent(
                        eventName: eventName,
                        payload: payload,
                        node: node,
                        actionExecutor: actionExecutor,
                        actionContext: actionContext
                    )
                }
            )

            // Render the custom component
            definition.factory(props, context)
        } else {
            // Not registered - show placeholder with key and version info
            UnregisteredComponentPlaceholder(componentKey: componentKey, version: componentVersion)
        }
    }

    /// Resolve all inputs from the unified input model
    private func resolveInputs(
        _ inputs: [String: ComponentInputValue]?,
        definition: CustomComponentDefinition
    ) -> [String: VariableValue] {
        var resolved: [String: VariableValue] = [:]

        guard let inputs = inputs else {
            Logger.shared.debug("CustomComponent: No inputs to resolve")
            return resolved
        }

        Logger.shared.debug("CustomComponent: Resolving \(inputs.count) inputs")

        for (key, inputValue) in inputs {
            switch inputValue {
            case .bind(let variablePath):
                // Look up the variable value from the store
                if let value = variableStore.get(variablePath) {
                    resolved[key] = value
                    Logger.shared.debug("CustomComponent: Input '\(key)' bound to '\(variablePath)' = \(value.displayString)")
                } else {
                    // Variable not found - use type default if declared
                    if let expectedType = definition.inputs?[key] {
                        resolved[key] = expectedType.defaultValue
                        Logger.shared.warn("CustomComponent: Input '\(key)' bound to '\(variablePath)' NOT FOUND, using type default: \(expectedType.defaultValue.displayString)")
                    } else {
                        Logger.shared.warn("CustomComponent: Input '\(key)' bound to '\(variablePath)' NOT FOUND, no type info available")
                    }
                }

            case .value(let constantValue):
                // Direct constant value
                resolved[key] = constantValue
                Logger.shared.debug("CustomComponent: Input '\(key)' = constant \(constantValue.displayString)")
            }
        }

        Logger.shared.debug("CustomComponent: Resolved inputs: \(resolved.mapValues { $0.displayString })")
        return resolved
    }
}

/// Handle events emitted by custom components by routing them through the interaction system
///
/// **Important**: For custom components, routing is ONLY done by `customEventKey`.
/// The `event` field (e.g., "onPress") is editor metadata and is completely ignored.
/// This ensures strict, predictable behavior where components emit events and
/// interactions match by exact string equality on `customEventKey`.
private func handleEmittedEvent(
    eventName: String,
    payload: [String: Any]?,
    node: ComponentNode,
    actionExecutor: ActionExecutor,
    actionContext: ActionContext
) {
    guard let interactions = node.interactions else {
        Logger.shared.debug("Custom component '\(node.id)' emitted '\(eventName)' but has no interactions defined")
        return
    }

    // For custom components: ONLY match by customEventKey (strict string equality)
    // The `event` field is editor metadata and is completely ignored
    for interaction in interactions {
        // Strict matching: customEventKey must exactly match the emitted event name
        guard let customEventKey = interaction.customEventKey else {
            continue
        }

        if customEventKey == eventName {
            Logger.shared.debug("Custom component '\(node.id)' event '\(eventName)' matched interaction '\(interaction.id)'")
            executeInteractionActions(
                interaction: interaction,
                eventName: eventName,
                payload: payload,
                node: node,
                actionExecutor: actionExecutor,
                actionContext: actionContext
            )
            return
        }
    }

    // Log available customEventKeys for debugging
    let availableKeys = interactions.compactMap { $0.customEventKey }
    if availableKeys.isEmpty {
        Logger.shared.debug("Custom component '\(node.id)' emitted '\(eventName)' but no interactions have customEventKey defined")
    } else {
        Logger.shared.debug("Custom component '\(node.id)' emitted '\(eventName)' but no matching customEventKey found. Available: \(availableKeys)")
    }
}

/// Execute the actions for a matched interaction
/// Payload is passed directly to the action executor for {{payload.*}} expression resolution
/// Payload is NOT stored in the VariableStore - it exists only during action execution
private func executeInteractionActions(
    interaction: ComponentInteraction,
    eventName: String,
    payload: [String: Any]?,
    node: ComponentNode,
    actionExecutor: ActionExecutor,
    actionContext: ActionContext
) {
    Task {
        await actionExecutor.execute(
            actions: interaction.actions,
            context: actionContext,
            payload: payload,
            elementId: node.id,
            elementType: "custom"
        )
    }
}

/// Placeholder shown when a custom component type is not registered
/// Shows component key and version for debugging
private struct UnregisteredComponentPlaceholder: View {
    let componentKey: String
    let version: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title)
                .foregroundColor(.orange)
            Text("Custom Component")
                .font(.caption)
                .fontWeight(.medium)
            Text(componentKey)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("v\(version)")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
            Text("Not Registered")
                .font(.caption2)
                .foregroundColor(.red.opacity(0.8))
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}
