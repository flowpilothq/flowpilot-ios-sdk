import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Ruler View

/// Renders the `ruler` primitive: a tick-mark measuring scale that drags under a
/// FIXED center indicator (the inverse of `slider`'s drag-the-thumb). It picks a
/// single continuous numeric value (snapped to `step`) and shows a big live
/// readout, e.g. the "What is your height? / weight?" onboarding screens. The
/// dashboard canvas (`ruler-renderer.tsx` / `ruler-geometry.ts`) paints the
/// STATIC at-rest state and is the visual-parity source of truth; this SDK
/// renders that same at-rest look and adds the live drag + snap + convert math.
///
/// Variable binding mirrors `SliderView`: the bound variable is read on appear,
/// written back live during the drag, and the node's `onChange` interaction is
/// fired once on release. The optional Imperial/Metric `unitToggle` REPLACES the
/// top-level scale with the active system's single `track`; switching preserves
/// the physical value via a canonical base (a single scalar convert, no column
/// splitting) and always writes the `canonicalSystem` track's normalized var.
struct RulerView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let renderTrigger: Int

    // Continuous scroll center (the value under the indicator, NOT snapped). At
    // rest it equals the snapped value; during a drag/fling it moves smoothly so
    // the whole tick comb slides under the finger (no stiff per-step jumps) and
    // momentum can ease it to a stop. The bound variable + readout snap to `step`.
    @State private var centerValue: Double = 0
    @State private var activeKey: String = ""
    @State private var loaded = false
    @State private var dragStartCenter: Double?
    // True while the release fling/settle animation runs, so an external variable
    // sync (our own write bumps renderTrigger) doesn't yank `centerValue` mid-fling.
    @State private var settling = false
    // The running decelerate-and-snap loop (cancelled if a new drag starts).
    @State private var settleTask: Task<Void, Never>?
    // Measured main-axis extent of the tick strip (width for horizontal, height
    // for vertical), driving the visible-tick window so the strip FILLS its size.
    @State private var stripExtent: CGFloat = 0

    private var props: ComponentProps? { node.props }

    // Fallback main-axis extents used before the first measure (and the vertical
    // default when no explicit height is set). The window then adapts to the
    // measured strip extent so a taller ruler shows more ticks.
    private let defaultHorizontalExtent: CGFloat = 393
    private let defaultVerticalStrip: CGFloat = 260
    // How far past the longest tick the center indicator pokes.
    private let indicatorOverhang: CGFloat = 14

    var body: some View {
        let _ = renderTrigger

        let orientation = PropertyResolver.resolve(props?.rulerOrientation, store: variableStore, default: "horizontal")
        let isVertical = orientation == "vertical"

        let config = buildToggleConfig()
        let track = activeTrack(config)

        let majorEvery = track.majorEvery
            ?? Int(PropertyResolver.resolve(props?.rulerMajorEvery, store: variableStore, default: 5.0).rounded())

        let scale = RulerGeometry.resolveScale(
            min: track.min,
            max: track.max,
            step: track.step,
            boundValue: centerValue,
            majorEvery: majorEvery
        )

        let visuals = resolveVisuals()
        // Continuous index of the center value (fractional during a drag/fling) —
        // the whole comb is positioned against this so it scrolls smoothly.
        let centerIndex = scale.step > 0 ? (centerValue - scale.min) / scale.step : Double(scale.selectedIndex)
        // The visible window FILLS the measured strip extent (so a taller ruler
        // shows more ticks). Seed with a sensible default before the first measure.
        let effectiveExtent = stripExtent > 0 ? stripExtent : (isVertical ? defaultVerticalStrip : defaultHorizontalExtent)
        let range = RulerGeometry.visibleRange(scale, tickSpacing: visuals.tickSpacing, halfSpan: effectiveExtent / 2)
        // A vertical ruler fills an EXPLICIT height; with none it stays a fixed
        // default tall scale (so it doesn't greedily eat the whole screen).
        let fillHeight = isVertical && props?.height != nil

        let showValueLabel = PropertyResolver.resolve(props?.showValueLabel, store: variableStore, default: true)
        let readout: String? = showValueLabel
            ? RulerGeometry.formatValue(scale.value, format: track.valueFormat, unit: track.unit, template: track.valueTemplate)
            : nil

        VStack(spacing: 0) {
            if isVertical {
                HStack(spacing: 16) {
                    readoutView(readout, visuals: visuals, isVertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    verticalStrip(scale: scale, range: range, centerIndex: centerIndex, visuals: visuals, fillHeight: fillHeight)
                        .gesture(dragGesture(track: track, config: config, tickSpacing: visuals.tickSpacing, isVertical: true))
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: fillHeight ? .infinity : nil)
            } else {
                VStack(spacing: 0) {
                    if let readout {
                        readoutView(readout, visuals: visuals, isVertical: false)
                            .padding(.bottom, 24)
                    }
                    horizontalStrip(scale: scale, range: range, centerIndex: centerIndex, visuals: visuals)
                        .gesture(dragGesture(track: track, config: config, tickSpacing: visuals.tickSpacing, isVertical: false))
                }
                .frame(maxWidth: .infinity)
            }

            if let config {
                toggleControl(config, visuals: visuals)
                    .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: fillHeight ? .infinity : nil)
        .onAppear { if !loaded { loadInitial(config); loaded = true } }
        .onChange(of: renderTrigger) { _ in syncFromVariable(config) }
    }

    // MARK: - Readout

    @ViewBuilder
    private func readoutView(_ readout: String?, visuals: RulerVisuals, isVertical: Bool) -> some View {
        if let readout {
            Text(readout)
                .font(.system(size: visuals.valueFontSize, weight: visuals.valueFontWeight))
                .foregroundColor(visuals.valueColor)
                .lineLimit(1)
                .fixedSize()
                .multilineTextAlignment(isVertical ? .leading : .center)
        } else {
            // Keep the vertical layout's flexible leading column even with no readout.
            Color.clear.frame(height: 0)
        }
    }

    // MARK: - Horizontal strip

    private func horizontalStrip(scale: RulerGeometry.Scale, range: (start: Int, end: Int), centerIndex: Double, visuals: RulerVisuals) -> some View {
        let stripHeight = visuals.majorTickLength + indicatorOverhang
        return ZStack(alignment: .bottom) {
            ForEach(range.start...max(range.start, range.end), id: \.self) { i in
                if i < scale.ticks.count {
                    let tick = scale.ticks[i]
                    RoundedRectangle(cornerRadius: visuals.tickThickness / 2)
                        .fill(tick.major ? visuals.majorTickColor : visuals.tickColor)
                        .frame(
                            width: visuals.tickThickness,
                            height: tick.major ? visuals.majorTickLength : visuals.minorTickLength
                        )
                        // Continuous offset against the (fractional) center index so
                        // the whole comb slides smoothly during a drag/fling.
                        .offset(x: CGFloat(Double(i) - centerIndex) * visuals.tickSpacing)
                }
            }
            // Center indicator (on top), bottom-anchored, poking `indicatorOverhang`
            // above the longest tick.
            RoundedRectangle(cornerRadius: visuals.indicatorThickness / 2)
                .fill(visuals.indicatorColor)
                .frame(width: visuals.indicatorThickness, height: stripHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: stripHeight, alignment: .bottom)
        .clipped()
        .contentShape(Rectangle())
        // Measure the filled width so the visible window spans the whole strip.
        .background(GeometryReader { geo in
            Color.clear.preference(key: RulerExtentKey.self, value: geo.size.width)
        })
        .onPreferenceChange(RulerExtentKey.self) { stripExtent = $0 }
    }

    // MARK: - Vertical strip

    private func verticalStrip(scale: RulerGeometry.Scale, range: (start: Int, end: Int), centerIndex: Double, visuals: RulerVisuals, fillHeight: Bool) -> some View {
        let stripWidth = visuals.majorTickLength + indicatorOverhang
        return ZStack(alignment: .trailing) {
            ForEach(range.start...max(range.start, range.end), id: \.self) { i in
                if i < scale.ticks.count {
                    let tick = scale.ticks[i]
                    RoundedRectangle(cornerRadius: visuals.tickThickness / 2)
                        .fill(tick.major ? visuals.majorTickColor : visuals.tickColor)
                        .frame(
                            width: tick.major ? visuals.majorTickLength : visuals.minorTickLength,
                            height: visuals.tickThickness
                        )
                        .offset(y: CGFloat(Double(i) - centerIndex) * visuals.tickSpacing)
                }
            }
            // Center indicator (on top), right-anchored.
            RoundedRectangle(cornerRadius: visuals.indicatorThickness / 2)
                .fill(visuals.indicatorColor)
                .frame(width: stripWidth, height: visuals.indicatorThickness)
        }
        // Fill an explicit height; otherwise stay a fixed default-tall scale.
        .frame(width: stripWidth, height: fillHeight ? nil : defaultVerticalStrip)
        .frame(maxHeight: fillHeight ? .infinity : nil)
        .clipped()
        .contentShape(Rectangle())
        // Measure the filled height so a taller ruler shows more ticks.
        .background(GeometryReader { geo in
            Color.clear.preference(key: RulerExtentKey.self, value: geo.size.height)
        })
        .onPreferenceChange(RulerExtentKey.self) { stripExtent = $0 }
    }

    // MARK: - Unit toggle controls

    @ViewBuilder
    private func toggleControl(_ config: RulerToggleConfig, visuals: RulerVisuals) -> some View {
        if isSwitchToggle(style: config.toggleStyle, optionCount: config.options.count) {
            switchControl(config, visuals: visuals)
        } else {
            segmentedControl(config, visuals: visuals)
        }
    }

    /// Static segmented Imperial | Metric pill, made tappable. Mirrors the
    /// dashboard `SegmentedControl`.
    private func segmentedControl(_ config: RulerToggleConfig, visuals: RulerVisuals) -> some View {
        HStack(spacing: 2) {
            ForEach(config.options.indices, id: \.self) { idx in
                let opt = config.options[idx]
                let active = opt.key == activeKey
                Text(opt.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(active ? visuals.toggleSelectedTextColor : visuals.toggleTextColor)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(active ? Color.white : Color.clear)
                            .shadow(color: active ? Color.black.opacity(0.12) : Color.clear, radius: 2, x: 0, y: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { switchSystem(to: opt.key, config: config) }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(visuals.toggleSelectionColor))
    }

    /// Switch-style toggle (label ─◯─ label), made tappable. The FIRST option is
    /// the OFF (knob-left) state, the SECOND is ON (knob-right). Mirrors the
    /// dashboard `SwitchControl` + shared `UnitSwitchMetrics` geometry.
    private func switchControl(_ config: RulerToggleConfig, visuals: RulerVisuals) -> some View {
        let firstKey = config.options[0].key
        let secondKey = config.options[1].key
        let knobRight = activeKey == secondKey
        let m = UnitSwitchMetrics.self

        return HStack(spacing: m.labelGap) {
            switchLabel(config.options[0].label, active: !knobRight, visuals: visuals)
                .onTapGesture { switchSystem(to: firstKey, config: config) }

            ZStack(alignment: knobRight ? .trailing : .leading) {
                Capsule()
                    .fill(m.trackColor)
                    .frame(width: m.trackWidth, height: m.trackHeight)
                Circle()
                    .fill(m.knobColor)
                    .frame(width: m.knobSize, height: m.knobSize)
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 1)
                    .padding(m.knobPadding)
            }
            .frame(width: m.trackWidth, height: m.trackHeight)
            .contentShape(Rectangle())
            .onTapGesture { switchSystem(to: knobRight ? firstKey : secondKey, config: config) }

            switchLabel(config.options[1].label, active: knobRight, visuals: visuals)
                .onTapGesture { switchSystem(to: secondKey, config: config) }
        }
    }

    private func switchLabel(_ text: String, active: Bool, visuals: RulerVisuals) -> some View {
        Text(text)
            .font(.system(size: UnitSwitchMetrics.labelFontSize, weight: active ? .bold : .semibold))
            .foregroundColor(active ? visuals.toggleSelectedTextColor : visuals.toggleTextColor)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
    }

    // MARK: - Drag

    private func dragGesture(track: RulerTrack, config: RulerToggleConfig?, tickSpacing: CGFloat, isVertical: Bool) -> some Gesture {
        let lo = Swift.min(track.min, track.max)
        let hi = Swift.max(track.min, track.max)
        let step = track.step
        let spacing = tickSpacing > 0 ? Double(tickSpacing) : 1
        return DragGesture(minimumDistance: 0)
            .onChanged { g in
                settling = false
                settleTask?.cancel()
                if dragStartCenter == nil { dragStartCenter = centerValue }
                let start = dragStartCenter ?? centerValue
                // Drag right → value down (horizontal); drag up → value up (vertical).
                // The center follows the finger CONTINUOUSLY (no per-step snap), so
                // the whole comb scrolls smoothly instead of jumping tick by tick.
                let axis = isVertical ? Double(g.translation.height) : Double(g.translation.width)
                let raw = start - (axis / spacing) * step
                let clamped = Swift.min(Swift.max(raw, lo), hi)
                if clamped != centerValue {
                    let prevSnapped = RulerGeometry.snapToStep(centerValue, lo, hi, step)
                    centerValue = clamped
                    commitIfStepChanged(prevSnapped: prevSnapped, track: track, config: config)
                }
            }
            .onEnded { g in
                let start = dragStartCenter ?? centerValue
                dragStartCenter = nil
                // Project where the flick would coast to (momentum) and decelerate
                // onto that tick — the iOS-ruler "slow to a stop" feel.
                let axis = isVertical ? Double(g.predictedEndTranslation.height) : Double(g.predictedEndTranslation.width)
                let target = RulerGeometry.snapToStep(start - (axis / spacing) * step, lo, hi, step)
                runSettle(from: centerValue, to: target, track: track, config: config)
            }
    }

    /// When the snapped value crosses to a new tick, write the bound variable +
    /// canonical var and fire a detent haptic.
    private func commitIfStepChanged(prevSnapped: Double, track: RulerTrack, config: RulerToggleConfig?) {
        let lo = Swift.min(track.min, track.max)
        let hi = Swift.max(track.min, track.max)
        let snapped = RulerGeometry.snapToStep(centerValue, lo, hi, track.step)
        guard snapped != prevSnapped else { return }
        commitValue(snapped, track: track, config: config, haptic: true)
    }

    /// Write a committed (snapped) value: the bound variable, the canonical
    /// normalized var, and an optional detent haptic.
    private func commitValue(_ snapped: Double, track: RulerTrack, config: RulerToggleConfig?, haptic: Bool) {
        if let key = track.variableKey { variableStore.set(key, value: .number(snapped)) }
        if let config { writeCanonical(base: UnitSystem.toBase(snapped, unit: track.unit), config: config) }
        if haptic {
            #if canImport(UIKit)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        }
    }

    /// Decelerate `centerValue` from `from` to the snapped `target` over a cubic
    /// ease-out, stepping every frame so the whole comb (and its visible window)
    /// slides smoothly — not just the on-screen ticks. Commits each tick it
    /// crosses (detent haptic) and the final value, then fires onChange.
    // Not `@MainActor`-isolated: this is invoked from a SwiftUI gesture's
    // `.onEnded` closure, which Swift 5.10 treats as nonisolated. The only
    // synchronous work here is cancelling/replacing the settle task and
    // flipping `settling` (the same `@State` the nonisolated `.onChanged`
    // already mutates); the actual frame-stepping runs in the inner
    // `Task { @MainActor in }`, so it stays on the main actor regardless.
    private func runSettle(from: Double, to target: Double, track: RulerTrack, config: RulerToggleConfig?) {
        settleTask?.cancel()
        let lo = Swift.min(track.min, track.max)
        let hi = Swift.max(track.min, track.max)
        let step = track.step
        let duration: TimeInterval = 0.42
        settling = true
        settleTask = Task { @MainActor in
            let startDate = Date()
            var lastSnapped = RulerGeometry.snapToStep(from, lo, hi, step)
            while !Task.isCancelled {
                let t = duration > 0 ? Swift.min(1, Date().timeIntervalSince(startDate) / duration) : 1
                let eased = 1 - pow(1 - t, 3)
                centerValue = from + (target - from) * eased
                let snapped = RulerGeometry.snapToStep(centerValue, lo, hi, step)
                if snapped != lastSnapped {
                    lastSnapped = snapped
                    commitValue(snapped, track: track, config: config, haptic: true)
                }
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            if Task.isCancelled { return }
            centerValue = target
            commitValue(target, track: track, config: config, haptic: false)
            fireOnChange()
            settling = false
            settleTask = nil
        }
    }

    // MARK: - Unit switch (scalar)

    private func switchSystem(to newKey: String, config: RulerToggleConfig) {
        guard newKey != activeKey,
              let current = config.options.first(where: { $0.key == activeKey }) ?? config.options.first,
              let target = config.options.first(where: { $0.key == newKey }) else { return }

        // 1. canonical base from the CURRENT value + unit.
        let base = UnitSystem.toBase(centerValue, unit: current.track.unit)

        // 2. switch + persist the active system key.
        activeKey = newKey
        if let key = config.systemVariableKey { variableStore.set(key, value: .string(newKey)) }

        // 3. convert the physical value into the new system, snap into its bounds.
        let lo = Swift.min(target.track.min, target.track.max)
        let hi = Swift.max(target.track.min, target.track.max)
        let converted = UnitSystem.fromBase(base, unit: target.track.unit)
        let newValue = RulerGeometry.snapToStep(converted, lo, hi, target.track.step)
        centerValue = newValue
        if let key = target.track.variableKey { variableStore.set(key, value: .number(newValue)) }

        // 4. ALWAYS write the canonical (normalized kg/cm) var.
        writeCanonical(base: base, config: config)

        // 5. fire onChange + haptic.
        fireOnChange()
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Write the canonical system's track var from a canonical base (kg/cm).
    private func writeCanonical(base: Double, config: RulerToggleConfig) {
        guard let canon = config.options.first(where: { $0.key == config.canonicalKey }),
              let key = canon.track.variableKey else { return }
        let canonValue = UnitSystem.fromBase(base, unit: canon.track.unit).rounded()
        variableStore.set(key, value: .number(canonValue))
    }

    // MARK: - State

    private func loadInitial(_ config: RulerToggleConfig?) {
        if let config {
            activeKey = resolveInitialKey(config)
            let track = (config.options.first(where: { $0.key == activeKey }) ?? config.options.first)?.track
            guard let track else { return }
            centerValue = initialValue(for: track)
            // Populate the canonical var up front so it is available pre-interaction.
            writeCanonical(base: UnitSystem.toBase(centerValue, unit: track.unit), config: config)
        } else {
            centerValue = initialValue(for: topLevelTrack())
        }
    }

    /// Initial value precedence: bound variable → track default → mid-range.
    private func initialValue(for track: RulerTrack) -> Double {
        let lo = Swift.min(track.min, track.max)
        let hi = Swift.max(track.min, track.max)
        if let key = track.variableKey, let n = variableStore.get(key)?.numberValue {
            return RulerGeometry.snapToStep(n, lo, hi, track.step)
        }
        if let d = track.defaultValue {
            return RulerGeometry.snapToStep(d, lo, hi, track.step)
        }
        return RulerGeometry.snapToStep((lo + hi) / 2, lo, hi, track.step)
    }

    private func resolveInitialKey(_ config: RulerToggleConfig) -> String {
        func valid(_ k: String?) -> String? {
            guard let k, config.options.contains(where: { $0.key == k }) else { return nil }
            return k
        }
        // Match the dashboard `resolveActiveRulerSystem` (default → first), with a
        // stored system var winning on the SDK like the picker.
        let stored = config.systemVariableKey.flatMap { variableStore.get($0)?.stringValue }
        return valid(stored) ?? valid(config.defaultKey) ?? config.options.first?.key ?? ""
    }

    private func syncFromVariable(_ config: RulerToggleConfig?) {
        // Ignore render-trigger bumps caused by our own live writes mid-drag/fling.
        guard dragStartCenter == nil, !settling else { return }
        syncCore(config)
    }

    private func syncCore(_ config: RulerToggleConfig?) {
        let track: RulerTrack
        if let config {
            // External system switch.
            if let key = config.systemVariableKey,
               let k = variableStore.get(key)?.stringValue,
               k != activeKey, config.options.contains(where: { $0.key == k }) {
                activeKey = k
            }
            guard let t = (config.options.first(where: { $0.key == activeKey }) ?? config.options.first)?.track else { return }
            track = t
        } else {
            track = topLevelTrack()
        }
        guard let key = track.variableKey, let n = variableStore.get(key)?.numberValue else { return }
        let lo = Swift.min(track.min, track.max)
        let hi = Swift.max(track.min, track.max)
        let snapped = RulerGeometry.snapToStep(n, lo, hi, track.step)
        if snapped != centerValue { centerValue = snapped }
    }

    // MARK: - Track / config resolution

    private func activeTrack(_ config: RulerToggleConfig?) -> RulerTrack {
        if let config {
            return (config.options.first(where: { $0.key == activeKey }) ?? config.options.first)?.track ?? topLevelTrack()
        }
        return topLevelTrack()
    }

    /// The single continuous scale from top-level props (no unit toggle).
    private func topLevelTrack() -> RulerTrack {
        let mn = PropertyResolver.resolve(props?.rulerMin, store: variableStore, default: 0.0)
        let mx = PropertyResolver.resolve(props?.rulerMax, store: variableStore, default: 100.0)
        var st = PropertyResolver.resolve(props?.rulerStep, store: variableStore, default: 1.0)
        if st <= 0 { st = 1 }
        let initial = PropertyResolver.resolve(props?.rulerValue, store: variableStore)
        let unit = PropertyResolver.resolveString(props?.rulerUnit, store: variableStore)
        let format = PropertyResolver.resolveString(props?.valueFormat, store: variableStore)
        let template = PropertyResolver.resolveString(props?.rulerValueTemplate, store: variableStore)
        return RulerTrack(
            variableKey: props?.variableKey,
            unit: unit,
            min: mn,
            max: mx,
            step: st,
            defaultValue: initial,
            valueFormat: format == "feetInches" ? "feetInches" : "plain",
            valueTemplate: template,
            majorEvery: nil
        )
    }

    private func buildToggleConfig() -> RulerToggleConfig? {
        guard let raw = props?.rulerUnitToggle,
              let rawOptions = RulerNumber.dictArray(raw["options"]), !rawOptions.isEmpty else { return nil }

        let systemVariableKey = raw["systemVariableKey"] as? String
        let defaultKey = raw["default"] as? String
        // Mirror the dashboard renderer EXACTLY: it picks switch-vs-segmented via
        // `isSwitchToggle(unitToggle.toggleStyle, count)` on the RAW value (only
        // the literal "switch" → switch control). Ruler presets bake in
        // toggleStyle:"switch"; an authored toggle without the field renders
        // segmented on the canvas, so we must too.
        let toggleStyle = (raw["toggleStyle"] as? String) == "switch" ? "switch" : "segmented"

        let options: [RulerSystem] = rawOptions.compactMap { od in
            guard let key = od["key"] as? String else { return nil }
            let label = od["label"] as? String ?? key
            let trackDict = od["track"] as? [String: Any] ?? [:]
            return RulerSystem(key: key, label: label, track: RulerTrack.build(trackDict))
        }
        guard !options.isEmpty else { return nil }

        // canonicalSystem: explicit key → option keyed "metric" → last option.
        let explicit = raw["canonicalSystem"] as? String
        let canonicalKey: String =
            (explicit.flatMap { k in options.contains(where: { $0.key == k }) ? k : nil })
            ?? (options.contains(where: { $0.key == "metric" }) ? "metric" : nil)
            ?? options.last?.key
            ?? ""

        return RulerToggleConfig(
            systemVariableKey: systemVariableKey,
            defaultKey: defaultKey,
            canonicalKey: canonicalKey,
            toggleStyle: toggleStyle,
            options: options
        )
    }

    // MARK: - Visuals

    private func resolveVisuals() -> RulerVisuals {
        let weightRaw = PropertyResolver.resolveString(props?.rulerValueFontWeight, store: variableStore) ?? "700"
        return RulerVisuals(
            tickSpacing: CGFloat(PropertyResolver.resolve(props?.rulerTickSpacing, store: variableStore, default: 12.0)),
            tickThickness: CGFloat(PropertyResolver.resolve(props?.rulerTickThickness, store: variableStore, default: 2.0)),
            minorTickLength: CGFloat(PropertyResolver.resolve(props?.rulerMinorTickLength, store: variableStore, default: 16.0)),
            majorTickLength: CGFloat(PropertyResolver.resolve(props?.rulerMajorTickLength, store: variableStore, default: 28.0)),
            indicatorThickness: CGFloat(PropertyResolver.resolve(props?.rulerIndicatorThickness, store: variableStore, default: 3.0)),
            tickColor: resolveColor(props?.rulerTickColor, defaultValue: "token:textTertiary", hexFallback: "#C7C7CC"),
            majorTickColor: resolveColor(props?.rulerMajorTickColor, defaultValue: "token:textSecondary", hexFallback: "#8E8E93"),
            indicatorColor: resolveColor(props?.rulerIndicatorColor, defaultValue: "token:primary", hexFallback: "#4F46E5"),
            valueColor: resolveColor(props?.rulerValueColor, defaultValue: "token:textPrimary", hexFallback: "#111827"),
            valueFontSize: CGFloat(PropertyResolver.resolve(props?.rulerValueFontSize, store: variableStore, default: 48.0)),
            valueFontWeight: RulerNumber.fontWeight(weightRaw),
            // Toggle colors mirror the dashboard: text falls back to #8E8E93 / value
            // falls back to #111827 (NOT the tick/value fallbacks) when the prop is absent.
            toggleSelectionColor: Color(hex: "rgba(120,120,128,0.16)") ?? Color.gray.opacity(0.16),
            toggleTextColor: resolveColorOrFallback(props?.rulerTickColor, hexFallback: "#8E8E93"),
            toggleSelectedTextColor: resolveColorOrFallback(props?.rulerValueColor, hexFallback: "#111827")
        )
    }

    /// Resolve a color prop, falling back to the documented DEFAULT TOKEN (then a
    /// hex literal) when the prop is absent. Mirrors `PickerView.resolveColor`.
    private func resolveColor(_ prop: PropertyValue<String>?, defaultValue: String, hexFallback: String) -> Color {
        let raw = PropertyResolver.resolve(prop, store: variableStore) ?? defaultValue
        let resolved = ThemeTokens.isRef(raw) ? variableStore.resolveThemeToken(raw) : raw
        return Color(hex: resolved) ?? Color(hex: hexFallback) ?? .primary
    }

    /// Resolve a color prop, falling back to a plain hex literal when the prop is
    /// absent (no default token) — matches the dashboard's toggle text colors,
    /// which use `(props.x as string) ?? hexFallback`.
    private func resolveColorOrFallback(_ prop: PropertyValue<String>?, hexFallback: String) -> Color {
        guard let raw = PropertyResolver.resolve(prop, store: variableStore) else {
            return Color(hex: hexFallback) ?? .primary
        }
        let resolved = ThemeTokens.isRef(raw) ? variableStore.resolveThemeToken(raw) : raw
        return Color(hex: resolved) ?? Color(hex: hexFallback) ?? .primary
    }

    // MARK: - Interaction

    private func fireOnChange() {
        guard let interaction = node.interactions?.first(where: { $0.event == .onChange }) else { return }
        Task {
            await actionExecutor.execute(
                actions: interaction.actions,
                context: actionContext,
                elementId: node.id,
                elementType: node.type.rawValue,
                interactionType: "change"
            )
        }
    }
}

// MARK: - Models

/// One unit system's single continuous scale (a ruler has no multi-column split).
private struct RulerTrack {
    let variableKey: String?
    let unit: String?
    let min: Double
    let max: Double
    let step: Double
    let defaultValue: Double?
    /// "plain" or "feetInches".
    let valueFormat: String
    let valueTemplate: String?
    /// Per-system major-tick interval override (nil → top-level `majorEvery`).
    let majorEvery: Int?

    /// Build a track from an untyped unit-system `track` dict.
    static func build(_ dict: [String: Any]) -> RulerTrack {
        let variableKey = dict["variableKey"] as? String
        let unit = dict["unit"] as? String
        let mn = RulerNumber.asDouble(dict["min"]) ?? 0
        let mx = RulerNumber.asDouble(dict["max"]) ?? 100
        var st = RulerNumber.asDouble(dict["step"]) ?? 1
        if st <= 0 { st = 1 }
        let defaultValue = RulerNumber.asDouble(dict["defaultValue"])
        let valueFormat = (dict["valueFormat"] as? String) == "feetInches" ? "feetInches" : "plain"
        let valueTemplate = dict["valueTemplate"] as? String
        let majorEvery = RulerNumber.asDouble(dict["majorEvery"]).map { Int($0.rounded()) }
        return RulerTrack(
            variableKey: variableKey,
            unit: unit,
            min: mn,
            max: mx,
            step: st,
            defaultValue: defaultValue,
            valueFormat: valueFormat,
            valueTemplate: valueTemplate,
            majorEvery: majorEvery
        )
    }
}

private struct RulerSystem {
    let key: String
    let label: String
    let track: RulerTrack
}

private struct RulerToggleConfig {
    let systemVariableKey: String?
    let defaultKey: String?
    let canonicalKey: String
    let toggleStyle: String
    let options: [RulerSystem]
}

private struct RulerVisuals {
    let tickSpacing: CGFloat
    let tickThickness: CGFloat
    let minorTickLength: CGFloat
    let majorTickLength: CGFloat
    let indicatorThickness: CGFloat
    let tickColor: Color
    let majorTickColor: Color
    let indicatorColor: Color
    let valueColor: Color
    let valueFontSize: CGFloat
    let valueFontWeight: Font.Weight
    let toggleSelectionColor: Color
    let toggleTextColor: Color
    let toggleSelectedTextColor: Color
}

// MARK: - Strip extent measurement

/// Carries the tick strip's measured main-axis extent (width for a horizontal
/// ruler, height for a vertical one) up so the visible-tick window FILLS it.
private struct RulerExtentKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = Swift.max(value, nextValue())
    }
}

// MARK: - Geometry (mirrors ruler-geometry.ts)

/// Pure helpers that turn a ruler scale into the tick list + selected index +
/// formatted readout, mirroring the dashboard `ruler-geometry.ts` EXACTLY (the
/// parity suite diffs the renders). Keep the three layers in lockstep.
private enum RulerGeometry {
    struct Tick {
        let value: Double
        let index: Int
        let major: Bool
    }

    struct Scale {
        let min: Double
        let max: Double
        let step: Double
        /// The snapped current value.
        let value: Double
        let ticks: [Tick]
        let selectedIndex: Int
        var count: Int { ticks.count }
    }

    /// Round to the nearest `step` within [min, max]. `minV`/`maxV` are passed
    /// pre-ordered (min ≤ max) like the dashboard's resolveRulerScale call sites.
    static func snapToStep(_ value: Double, _ minV: Double, _ maxV: Double, _ step: Double) -> Double {
        let s = step > 0 ? step : 1
        let lo = Swift.min(minV, maxV)
        let hi = Swift.max(minV, maxV)
        let clamped = Swift.min(Swift.max(value, lo), hi)
        let snapped = ((clamped - minV) / s).rounded() * s + minV
        let rounded = (snapped * 1e6).rounded() / 1e6
        return Swift.min(Swift.max(rounded, lo), hi)
    }

    /// Build the tick list + selected index for a ruler scale. Selection
    /// precedence here: live bound value (always provided by the SDK) snapped.
    static func resolveScale(min rawMin: Double, max rawMax: Double, step rawStep: Double, boundValue: Double, majorEvery rawMajor: Int) -> Scale {
        let minV = Swift.min(rawMin, rawMax)
        let maxV = Swift.max(rawMin, rawMax)
        let step = rawStep > 0 ? rawStep : 1
        let majorEvery = rawMajor > 0 ? rawMajor : 5

        let maxTicks = 10000
        var ticks: [Tick] = []
        var v = minV
        var i = 0
        while v <= maxV + 1e-9 && i < maxTicks {
            let value = (v * 1e6).rounded() / 1e6
            ticks.append(Tick(value: value, index: i, major: i % majorEvery == 0))
            v += step
            i += 1
        }
        if ticks.isEmpty { ticks.append(Tick(value: minV, index: 0, major: true)) }

        let snapped = snapToStep(boundValue, minV, maxV, step)
        var selectedIndex = Int(((snapped - minV) / step).rounded())
        selectedIndex = Swift.max(0, Swift.min(ticks.count - 1, selectedIndex))

        return Scale(min: minV, max: maxV, step: step, value: snapped, ticks: ticks, selectedIndex: selectedIndex)
    }

    /// Pixel offset of a tick relative to the centered (selected) tick.
    static func tickOffset(_ scale: Scale, index: Int, tickSpacing: CGFloat) -> CGFloat {
        CGFloat(index - scale.selectedIndex) * tickSpacing
    }

    /// Inclusive tick index range whose offset falls within ±halfSpan of center
    /// (plus a one-tick margin), so only the visible window is painted.
    static func visibleRange(_ scale: Scale, tickSpacing: CGFloat, halfSpan: CGFloat) -> (start: Int, end: Int) {
        let spacing = tickSpacing > 0 ? tickSpacing : 1
        let reach = Int((halfSpan / spacing).rounded(.up)) + 1
        let start = Swift.max(0, scale.selectedIndex - reach)
        let end = Swift.min(scale.count - 1, scale.selectedIndex + reach)
        return (start, end)
    }

    /// Split total inches into whole feet + remaining inches, rolling over 12".
    static func inchesToFeetInches(_ totalInches: Double) -> (feet: Int, inches: Int) {
        let rounded = Int(totalInches.rounded())
        var feet = Int(floor(Double(rounded) / 12.0))
        var inches = rounded - feet * 12
        if inches == 12 {
            feet += 1
            inches = 0
        }
        return (feet, inches)
    }

    /// The big readout string. `feetInches` renders total inches as `6'1"`;
    /// `plain` substitutes `{{value}}` into `template` (default `"<value> <unit>"`,
    /// or just the number when there is no unit).
    static func formatValue(_ value: Double, format: String?, unit: String?, template: String?) -> String {
        if format == "feetInches" {
            let parts = inchesToFeetInches(value)
            return "\(parts.feet)'\(parts.inches)\""
        }
        let shown = RulerNumber.format((value * 1e6).rounded() / 1e6)
        if let t = template, t.contains("{{value}}") {
            let replaced = t.replacingOccurrences(
                of: #"\{\{\s*value\s*\}\}"#,
                with: shown,
                options: .regularExpression
            )
            return replaced.trimmingCharacters(in: .whitespaces)
        }
        if let u = unit, !u.isEmpty {
            return "\(shown) \(u)".trimmingCharacters(in: .whitespaces)
        }
        return shown
    }
}

// MARK: - Numeric helpers

private enum RulerNumber {
    /// Coerce a JSON-decoded value to a Double.
    static func asDouble(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let f as CGFloat: return Double(f)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Conditionally downcast a JSON-decoded array to `[[String: Any]]`.
    static func dictArray(_ value: Any?) -> [[String: Any]]? {
        guard let arr = value as? [Any] else { return value as? [[String: Any]] }
        let dicts = arr.compactMap { $0 as? [String: Any] }
        return dicts.isEmpty ? nil : dicts
    }

    /// Format a number the way the editor does: integral values drop the decimal
    /// ("57"), fractional values stay compact ("57.5").
    static func format(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 {
            return String(Int(n))
        }
        return String(format: "%g", n)
    }

    /// Map a CSS font-weight string to a SwiftUI `Font.Weight` (default bold/700).
    static func fontWeight(_ raw: String) -> Font.Weight {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "100": return .ultraLight
        case "200": return .thin
        case "300", "light": return .light
        case "400", "normal", "regular": return .regular
        case "500", "medium": return .medium
        case "600", "semibold": return .semibold
        case "700", "bold": return .bold
        case "800": return .heavy
        case "900", "black": return .black
        default: return .bold
        }
    }
}
