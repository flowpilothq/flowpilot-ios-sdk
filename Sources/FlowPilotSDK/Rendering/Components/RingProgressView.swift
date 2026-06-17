import SwiftUI

// MARK: - Ring Progress View

/// Renders a `ringProgress` primitive: circular progress as a separate
/// primitive from `progress` (overhaul §3.1). The arc starts at the top
/// (rotated -90deg) and sweeps clockwise. Children render centered over the
/// ring via `ComponentRenderer` recursion (the "30% in the middle" pattern).
///
/// When the node carries an `autoProgress` timeline, the ring drives ITSELF:
/// it eases through staged targets, pausing at each, with a live percent in the
/// center and a per-stage caption below — the "Analyzing… / Finalizing…"
/// onboarding loader (`AutoProgressRing`). Mirrors the dashboard canvas + Expo.
@MainActor
struct RingProgressView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let mediaBaseUrl: String?
    let iconBaseUrl: String?
    var renderTrigger: Int = 0

    private var props: ComponentProps? { node.props }

    private var isIndeterminate: Bool {
        PropertyResolver.resolve(props?.mode, store: variableStore, default: "determinate") == "indeterminate"
    }

    private var value: Double {
        let raw = PropertyResolver.resolve(props?.progressValue, store: variableStore, default: 0.0)
        return max(0, min(1, raw))
    }

    private var size: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.ringSize, store: variableStore, default: 96.0))
    }

    private var strokeWidth: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.strokeWidth, store: variableStore, default: 8.0))
    }

    private var color: Color {
        let hex = PropertyResolver.resolve(props?.color, store: variableStore, default: "#4F46E5")
        return Color(hex: hex) ?? .blue
    }

    private var trackColor: Color {
        let hex = PropertyResolver.resolve(props?.trackColor, store: variableStore, default: "#E5E7EB")
        return Color(hex: hex) ?? Color(red: 0.9, green: 0.9, blue: 0.92)
    }

    private var animateOnAppear: Bool {
        PropertyResolver.resolve(props?.animateOnAppear, store: variableStore, default: true)
    }

    private var revealOnAppear: Bool {
        PropertyResolver.resolve(props?.revealOnAppear, store: variableStore, default: false)
    }

    private var animationDuration: Double {
        PropertyResolver.resolve(props?.animationDuration, store: variableStore, default: 800.0)
    }

    private var animationCurve: String {
        PropertyResolver.resolve(props?.animationCurve, store: variableStore, default: "ease-out")
    }

    // MARK: autoProgress label styling

    private var percentFontSize: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.percentFontSize, store: variableStore, default: Double(size) * 0.26))
    }
    private var percentColor: Color {
        Color(hex: PropertyResolver.resolve(props?.percentColor, store: variableStore, default: "#111827")) ?? .primary
    }
    private var percentWeight: Font.Weight {
        ringFontWeight(from: PropertyResolver.resolve(props?.percentFontWeight, store: variableStore, default: "700"))
    }
    private var captionFontSize: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.captionFontSize, store: variableStore, default: 17.0))
    }
    private var captionColor: Color {
        Color(hex: PropertyResolver.resolve(props?.captionColor, store: variableStore, default: "#111827")) ?? .primary
    }
    private var captionWeight: Font.Weight {
        ringFontWeight(from: PropertyResolver.resolve(props?.captionFontWeight, store: variableStore, default: "600"))
    }
    private var captionSpacing: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.captionSpacing, store: variableStore, default: 24.0))
    }

    var body: some View {
        let _ = renderTrigger
        if let auto = props?.ringAutoProgress {
            AutoProgressRing(
                config: auto,
                size: size,
                strokeWidth: strokeWidth,
                color: color,
                trackColor: trackColor,
                percentFontSize: percentFontSize,
                percentColor: percentColor,
                percentWeight: percentWeight,
                captionFontSize: captionFontSize,
                captionColor: captionColor,
                captionWeight: captionWeight,
                captionSpacing: captionSpacing,
                onComplete: fireOnComplete
            )
        } else if isIndeterminate {
            IndeterminateRing(size: size, strokeWidth: strokeWidth, color: color, trackColor: trackColor, duration: animationDuration)
                .overlay(centerContent)
        } else {
            DeterminateRing(
                size: size,
                strokeWidth: strokeWidth,
                color: color,
                trackColor: trackColor,
                value: value,
                animate: animateOnAppear || revealOnAppear,
                duration: animationDuration,
                curve: animationCurve
            )
            .overlay(centerContent)
        }
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

    @ViewBuilder
    private var centerContent: some View {
        if let children = node.children, !children.isEmpty {
            VStack(spacing: 0) {
                ForEach(children.indices, id: \.self) { index in
                    ComponentRenderer(
                        node: children[index],
                        variableStore: variableStore,
                        actionExecutor: actionExecutor,
                        actionContext: actionContext,
                        mediaBaseUrl: mediaBaseUrl,
                        iconBaseUrl: iconBaseUrl,
                        renderTrigger: renderTrigger
                    )
                }
            }
        }
    }
}

// MARK: - Auto Progress Ring (self-driving analysis loader)

private struct AutoProgressRing: View {
    let config: RingAutoProgress
    let size: CGFloat
    let strokeWidth: CGFloat
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

    private var schedule: RingAutoSchedule { buildRingAutoSchedule(config.stages) }
    private var hasCaption: Bool { config.stages.contains { !($0.caption ?? "").isEmpty } }

    var body: some View {
        let schedule = self.schedule
        // One TimelineView drives the arc, the center percent, and the caption
        // from a single sample so they never drift.
        TimelineView(.animation) { ctx in
            let elapsedMs = ctx.date.timeIntervalSince(start) * 1000
            let sample = sampleRingAuto(schedule, easing: config.easing, elapsedMs: elapsedMs, loop: config.loop)
            VStack(spacing: 0) {
                ZStack {
                    Circle().stroke(trackColor, lineWidth: strokeWidth)
                    Circle()
                        .trim(from: 0, to: CGFloat(sample.value))
                        .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if config.showPercent {
                        Text("\(Int((sample.value * 100).rounded()))\(config.percentSuffix)")
                            .font(.system(size: percentFontSize, weight: percentWeight))
                            .foregroundColor(percentColor)
                    }
                }
                .frame(width: size, height: size)

                if hasCaption {
                    Text(sample.caption ?? "")
                        .font(.system(size: captionFontSize, weight: captionWeight))
                        .foregroundColor(captionColor)
                        .multilineTextAlignment(.center)
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

    private func scheduleComplete() {
        completeWork?.cancel()
        guard !config.loop, !config.onComplete.isEmpty else { return }
        let totalSec = schedule.total / 1000.0
        let work = DispatchWorkItem { onComplete() }
        completeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, totalSec), execute: work)
    }

    /// Fire one haptic each time the ring reaches a stage's target (the start of
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

// MARK: - Auto Progress schedule math (mirrors dashboard + Expo)

private struct RingAutoSegment {
    let start: Double
    let end: Double
    let from: Double
    let to: Double
    let caption: String?
    let hold: Bool
}

private struct RingAutoSchedule {
    let segments: [RingAutoSegment]
    let total: Double
    let finalValue: Double
}

private func buildRingAutoSchedule(_ stages: [RingAutoProgressStage]) -> RingAutoSchedule {
    var segments: [RingAutoSegment] = []
    var t = 0.0
    var prev = 0.0
    for stage in stages {
        let target = max(0, min(1, stage.target))
        let ramp = max(0, stage.rampMs)
        let hold = max(0, stage.holdMs)
        if ramp > 0 {
            segments.append(RingAutoSegment(start: t, end: t + ramp, from: prev, to: target, caption: stage.caption, hold: false))
            t += ramp
        }
        segments.append(RingAutoSegment(start: t, end: t + hold, from: target, to: target, caption: stage.caption, hold: true))
        t += hold
        prev = target
    }
    return RingAutoSchedule(segments: segments, total: t, finalValue: prev)
}

private func ringEase(_ curve: String, _ t: Double) -> Double {
    let x = max(0, min(1, t))
    switch curve {
    case "linear": return x
    case "ease-in": return x * x
    case "ease-out": return 1 - (1 - x) * (1 - x)
    default: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}

private func sampleRingAuto(
    _ schedule: RingAutoSchedule,
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
            return (seg.from + (seg.to - seg.from) * ringEase(easing, local), seg.caption)
        }
    }
    return (schedule.finalValue, last.caption)
}

private func ringFontWeight(from raw: String) -> Font.Weight {
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

// MARK: - Determinate Ring

private struct DeterminateRing: View {
    let size: CGFloat
    let strokeWidth: CGFloat
    let color: Color
    let trackColor: Color
    let value: Double
    let animate: Bool
    let duration: Double
    let curve: String

    @State private var animatedValue: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: animatedValue)
                .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .onAppear {
            if animate {
                withAnimation(resolvedAnimation) { animatedValue = value }
            } else {
                animatedValue = value
            }
        }
        .onChange(of: value) { newValue in
            if animate {
                withAnimation(resolvedAnimation) { animatedValue = newValue }
            } else {
                animatedValue = newValue
            }
        }
    }

    private var resolvedAnimation: Animation {
        let seconds = duration / 1000.0
        switch curve {
        case "linear": return .linear(duration: seconds)
        case "ease-in": return .easeIn(duration: seconds)
        case "ease-out": return .easeOut(duration: seconds)
        case "ease-in-out", "ease": return .easeInOut(duration: seconds)
        default: return .easeOut(duration: seconds)
        }
    }
}

// MARK: - Indeterminate Ring

private struct IndeterminateRing: View {
    let size: CGFloat
    let strokeWidth: CGFloat
    let color: Color
    let trackColor: Color
    let duration: Double

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: max(0.1, duration / 1000.0)).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
