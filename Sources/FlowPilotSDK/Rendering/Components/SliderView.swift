import SwiftUI

// MARK: - Slider View

/// Renders a `slider` primitive: a numeric range control with two-way variable
/// binding. Binding mirrors `InputView` (overhaul §3.4): the bound variable is
/// read on appear, written back on every change, and an `onChange` interaction
/// is fired.
///
/// This is a custom track (not a wrapped `Slider`) so that all three color
/// props -- `trackColor`, `fillColor`, `thumbColor` -- are honored
/// independently. SwiftUI's native `Slider` only exposes a single `.tint`,
/// which cannot color the unfilled track and thumb separately. The custom
/// track also matches the dashboard preview and Expo's three-color native
/// slider for cross-layer parity.
struct SliderView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let renderTrigger: Int

    @State private var currentValue: Double = 0

    private var props: ComponentProps? { node.props }
    private var variableKey: String? { props?.variableKey }

    private var minValue: Double { PropertyResolver.resolve(props?.sliderMin, store: variableStore, default: 0.0) }
    private var maxValue: Double { PropertyResolver.resolve(props?.sliderMax, store: variableStore, default: 100.0) }
    private var step: Double {
        let s = PropertyResolver.resolve(props?.sliderStep, store: variableStore, default: 1.0)
        return s > 0 ? s : 1.0
    }

    private var trackColor: Color {
        Color(hex: PropertyResolver.resolve(props?.trackColor, store: variableStore, default: "#E5E7EB")) ?? Color.gray.opacity(0.3)
    }
    private var fillColor: Color {
        Color(hex: PropertyResolver.resolve(props?.sliderFillColor, store: variableStore, default: "#4F46E5")) ?? .blue
    }
    private var thumbColor: Color {
        Color(hex: PropertyResolver.resolve(props?.sliderThumbColor, store: variableStore, default: "#4F46E5")) ?? .blue
    }
    private var showValueLabel: Bool {
        PropertyResolver.resolve(props?.showValueLabel, store: variableStore, default: false)
    }

    private var fraction: CGFloat {
        guard maxValue > minValue else { return 0 }
        return CGFloat((currentValue - minValue) / (maxValue - minValue))
    }

    // MARK: - Modern styling (additive; defaults preserve the legacy look)

    /// Thickness of the track & fill (default 6).
    private var trackHeight: CGFloat {
        CGFloat(PropertyResolver.resolve(props?.sliderTrackHeight, store: variableStore, default: 6.0))
    }

    /// Trailing fill color hex when a gradient is configured; nil ⇒ solid fill.
    private var fillColorEndHex: String? {
        guard let hex = PropertyResolver.resolve(props?.sliderFillColorEnd, store: variableStore),
              !hex.isEmpty else { return nil }
        return hex
    }

    /// Fill style: a leading→trailing gradient when `fillColorEnd` is set,
    /// otherwise a solid `fillColor`.
    private var fillStyle: AnyShapeStyle {
        if let endHex = fillColorEndHex, let endColor = Color(hex: endHex) {
            return AnyShapeStyle(
                LinearGradient(colors: [fillColor, endColor], startPoint: .leading, endPoint: .trailing)
            )
        }
        return AnyShapeStyle(fillColor)
    }

    /// "circle" (default) or "pill".
    private var thumbStyle: String {
        PropertyResolver.resolve(props?.sliderThumbStyle, store: variableStore, default: "circle")
    }

    /// Thumb width: circle diameter (default 18) or pill width (default 28).
    private var thumbW: CGFloat {
        let defaultW: Double = thumbStyle == "pill" ? 28 : 18
        return CGFloat(PropertyResolver.resolve(props?.sliderThumbSize, store: variableStore, default: defaultW))
    }

    /// Pill thumb height (a vertical capsule), clamped to [36, 60].
    private var pillHeight: CGFloat {
        max(36, min(60, trackHeight + 30))
    }

    /// Thumb height: `pillHeight` for the pill style, otherwise `thumbW`.
    private var thumbH: CGFloat {
        thumbStyle == "pill" ? pillHeight : thumbW
    }

    /// Vertical extent of the interactive track row.
    private var rowHeight: CGFloat {
        max(trackHeight, thumbH)
    }

    /// "inline" (default) or "top".
    private var valueLabelPosition: String {
        PropertyResolver.resolve(props?.sliderValueLabelPosition, store: variableStore, default: "inline")
    }

    /// Readout font size (default 14 inline, 40 top).
    private var valueLabelSize: CGFloat {
        let def: Double = valueLabelPosition == "top" ? 40 : 14
        return CGFloat(PropertyResolver.resolve(props?.sliderValueLabelSize, store: variableStore, default: def))
    }

    /// Readout color. Default: inline = secondary/gray; top = the resolved `fillColor`.
    private var valueLabelColor: Color {
        if let hex = PropertyResolver.resolve(props?.sliderValueLabelColor, store: variableStore),
           !hex.isEmpty, let c = Color(hex: hex) {
            return c
        }
        return valueLabelPosition == "top" ? fillColor : .secondary
    }

    // MARK: - Body

    var body: some View {
        let _ = renderTrigger
        Group {
            if showValueLabel && valueLabelPosition == "top" {
                VStack(spacing: 12) {
                    Text(formattedValue)
                        .font(.system(size: valueLabelSize, weight: .heavy))
                        .foregroundColor(valueLabelColor)
                    trackRow
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 12) {
                    trackRow
                    if showValueLabel {
                        Text(formattedValue)
                            .font(.system(size: valueLabelSize, weight: .medium))
                            .foregroundColor(valueLabelColor)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { loadInitialValue() }
        .onChange(of: renderTrigger) { _ in syncFromVariable() }
    }

    /// The interactive track row: track + fill + thumb measured by a
    /// `GeometryReader` so the drag maps the touch x across the FULL track
    /// width. The hit area covers the full `rowHeight`.
    private var trackRow: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(fillStyle)
                    .frame(width: width * clamped, height: trackHeight)
                thumb
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                    .offset(x: width * clamped - thumbW / 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Write the bound variable live during the drag so
                        // anything else bound to it (e.g. a ring) reacts.
                        updateValue(fromX: value.location.x, width: width)
                    }
                    .onEnded { _ in
                        // Fire the onChange interaction once per gesture
                        // (on release) rather than per micro-step.
                        fireInteraction(event: .onChange)
                    }
            )
        }
        .frame(height: rowHeight)
    }

    /// The draggable thumb: a `Circle` (circle style) or a vertical capsule
    /// `RoundedRectangle` (pill style), centered on the fill's trailing edge.
    @ViewBuilder
    private var thumb: some View {
        if thumbStyle == "pill" {
            RoundedRectangle(cornerRadius: thumbW / 2)
                .fill(thumbColor)
                .frame(width: thumbW, height: pillHeight)
        } else {
            Circle()
                .fill(thumbColor)
                .frame(width: thumbW, height: thumbW)
        }
    }

    // MARK: - Value Mapping

    private func updateValue(fromX x: CGFloat, width: CGFloat) {
        guard width > 0, maxValue > minValue else { return }
        let pct = Double(max(0, min(1, x / width)))
        let raw = minValue + pct * (maxValue - minValue)
        let snapped = (raw / step).rounded() * step
        let bounded = max(minValue, min(maxValue, snapped))
        if bounded != currentValue {
            currentValue = bounded
            syncToVariable(bounded)
        }
    }

    // MARK: - Variable Binding

    private func loadInitialValue() {
        if let key = variableKey, let stored = variableStore.get(key), let num = stored.numberValue {
            currentValue = clampToRange(num)
            return
        }
        let initial = PropertyResolver.resolve(props?.sliderValue, store: variableStore, default: minValue)
        currentValue = clampToRange(initial)
    }

    private func syncFromVariable() {
        guard let key = variableKey, let stored = variableStore.get(key), let num = stored.numberValue else { return }
        let bounded = clampToRange(num)
        if bounded != currentValue {
            currentValue = bounded
        }
    }

    private func syncToVariable(_ value: Double) {
        guard let key = variableKey else { return }
        variableStore.set(key, value: .number(value))
    }

    private func clampToRange(_ value: Double) -> Double {
        max(minValue, min(maxValue, value))
    }

    // MARK: - Formatting

    private var formattedValue: String {
        let numberString = currentValue == currentValue.rounded()
            ? String(Int(currentValue))
            : String(currentValue)
        if let format = PropertyResolver.resolveString(props?.valueFormat, store: variableStore), !format.isEmpty {
            return format.replacingOccurrences(
                of: #"\{\{?\s*value\s*\}?\}"#,
                with: numberString,
                options: .regularExpression
            )
        }
        return numberString
    }

    // MARK: - Event Handlers

    private func fireInteraction(event: ComponentEventType) {
        guard let interaction = node.interactions?.first(where: { $0.event == event }) else { return }
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
