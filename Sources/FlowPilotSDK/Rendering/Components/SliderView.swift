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

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 20

    var body: some View {
        let _ = renderTrigger
        HStack(spacing: 12) {
            GeometryReader { geo in
                let width = geo.size.width
                let clamped = max(0, min(1, fraction))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackColor)
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: width * clamped, height: trackHeight)
                    Circle()
                        .fill(thumbColor)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                        .offset(x: width * clamped - thumbSize / 2)
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
            .frame(height: thumbSize)

            if showValueLabel {
                Text(formattedValue)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { loadInitialValue() }
        .onChange(of: renderTrigger) { _ in syncFromVariable() }
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
