import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
extension Notification.Name {
    /// Posted by InputView when it gains focus, with userInfo["nodeId"] containing the node ID.
    static let flowPilotInputFocused = Notification.Name("flowPilotInputFocused")
}
#endif

// MARK: - Input View

/// Renders a text input component with full variable binding, multiline support,
/// validation, number filtering, and keyboard configuration.
struct InputView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let renderTrigger: Int

    @State private var text: String = ""
    @State private var validationMessage: String? = nil
    @FocusState private var isFocused: Bool

    private var props: ComponentProps? { node.props }
    private var variableKey: String? { props?.variableKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: resolvedInputType == "multiline" ? .topLeading : .leading) {
                // Custom placeholder overlay for all input types
                // (SwiftUI's native placeholder doesn't support custom colors
                // and gets overridden by .foregroundColor)
                if text.isEmpty {
                    Text(resolvedPlaceholder)
                        .foregroundColor(resolvedPlaceholderColor)
                        .font(resolvedFont)
                        .padding(resolvedInputType == "multiline" ? .vertical : [], 8)
                        .allowsHitTesting(false)
                }

                Group {
                    switch resolvedInputType {
                    case "multiline":
                        multilineInput
                    case "password":
                        SecureField("", text: $text)
                    default:
                        standardInput
                    }
                }
            }
            .font(resolvedFont)
            .foregroundColor(resolvedColor)
            .focused($isFocused)
            #if os(iOS)
            .textInputAutocapitalization(resolvedAutocapitalization)
            .autocorrectionDisabled(resolvedAutocorrectionDisabled)
            #endif
            .onAppear { loadInitialValue() }
            .onChange(of: text) { newValue in
                sanitizeInput(newValue)
                syncToVariable(text)
                fireInteraction(event: .onChange)
            }
            .onChange(of: isFocused) { focused in
                if focused {
                    #if os(iOS)
                    NotificationCenter.default.post(
                        name: .flowPilotInputFocused,
                        object: nil,
                        userInfo: ["nodeId": node.id]
                    )
                    #endif
                    fireInteraction(event: .onFocus)
                } else {
                    runValidation(text)
                    fireInteraction(event: .onBlur)
                }
            }
            .onChange(of: renderTrigger) { _ in
                // Reload from variable store if changed externally (e.g. "Clear" button)
                guard let key = variableKey,
                      let stored = variableStore.get(key) else { return }
                let storedString = stored.displayString
                if storedString != text {
                    text = storedString
                }
            }

            if let msg = validationMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .id(node.id)
    }

    // MARK: - Input Variants

    @ViewBuilder
    private var standardInput: some View {
        #if os(iOS)
        TextField("", text: $text)
            .keyboardType(resolvedKeyboardType)
            .submitLabel(resolvedSubmitLabel)
        #else
        TextField("", text: $text)
        #endif
    }

    @ViewBuilder
    private var multilineInput: some View {
        let rowCount = PropertyResolver.resolve(props?.rows, store: variableStore, default: 3.0)
        Group {
            if #available(iOS 16.0, macOS 13.0, *) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
            } else {
                TextEditor(text: $text)
            }
        }
        .frame(minHeight: CGFloat(rowCount) * 20)
    }

    // MARK: - Variable Binding

    private func loadInitialValue() {
        guard let key = variableKey else { return }
        if let stored = variableStore.get(key) {
            text = stored.displayString
        }
    }

    private func syncToVariable(_ value: String) {
        guard let key = variableKey else { return }
        let varValue: VariableValue = resolvedInputType == "number"
            ? .number(Double(value) ?? 0)
            : .string(value)
        variableStore.set(key, value: varValue)
    }

    // MARK: - Input Sanitization

    private func sanitizeInput(_ newValue: String) {
        var sanitized = newValue
        if resolvedInputType == "number" {
            sanitized = filterForNumber(sanitized)
        }
        if let max = PropertyResolver.resolve(props?.maxLength, store: variableStore) as Double?,
           max > 0, sanitized.count > Int(max) {
            sanitized = String(sanitized.prefix(Int(max)))
        }
        if sanitized != newValue {
            text = sanitized
        }
    }

    private func filterForNumber(_ value: String) -> String {
        let filtered = value.filter { $0.isNumber || $0 == "." || $0 == "-" }
        let parts = filtered.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 {
            return String(parts[0]) + "." + String(parts[1])
        }
        return filtered
    }

    // MARK: - Validation

    private func runValidation(_ value: String) {
        guard let validationDict = props?.inputValidation,
              let validation = InputValidation(from: validationDict) else {
            validationMessage = nil
            return
        }
        validationMessage = validation.validate(value).errorMessage
    }

    // MARK: - Property Resolution

    private var resolvedInputType: String {
        PropertyResolver.resolve(props?.inputType, store: variableStore, default: "text")
    }

    private var resolvedPlaceholder: String {
        PropertyResolver.resolveString(props?.placeholder, store: variableStore, default: "")
    }

    private var resolvedPlaceholderColor: Color {
        let colorStr = PropertyResolver.resolve(props?.placeholderColor, store: variableStore, default: "#999999")
        return Color(hex: colorStr) ?? .gray
    }

    private var resolvedFont: Font {
        let size = PropertyResolver.resolve(props?.fontSize, store: variableStore, default: 16.0)
        let weight = PropertyResolver.resolve(props?.fontWeight, store: variableStore, default: "400")
        let family: String? = PropertyResolver.resolve(props?.fontFamily, store: variableStore)
        let fontWeight = FontManager.swiftUIWeight(from: weight)
        return FontManager.resolveSwiftUIFont(family: family, weight: fontWeight, size: CGFloat(size))
    }

    private var resolvedColor: Color {
        let colorStr = PropertyResolver.resolve(props?.color, store: variableStore, default: "#000000")
        return Color(hex: colorStr) ?? .primary
    }

    #if os(iOS)
    private var resolvedKeyboardType: UIKeyboardType {
        switch resolvedInputType {
        case "email": return .emailAddress
        case "number": return .decimalPad
        case "phone", "tel": return .phonePad
        case "url": return .URL
        case "search": return .webSearch
        default: return .default
        }
    }

    private var resolvedSubmitLabel: SubmitLabel {
        let type = PropertyResolver.resolve(props?.returnKeyType, store: variableStore, default: "done")
        switch type {
        case "go": return .go
        case "next": return .next
        case "search": return .search
        case "send": return .send
        case "done": return .done
        default: return .done
        }
    }

    private var resolvedAutocapitalization: TextInputAutocapitalization {
        switch resolvedInputType {
        case "email", "url", "password": return .never
        default: return .sentences
        }
    }

    private var resolvedAutocorrectionDisabled: Bool {
        switch resolvedInputType {
        case "email", "url", "password": return true
        default: return false
        }
    }
    #endif

    // MARK: - Event Handlers

    private func fireInteraction(event: ComponentEventType) {
        if let interaction = node.interactions?.first(where: { $0.event == event }) {
            Task {
                await actionExecutor.execute(
                    actions: interaction.actions,
                    context: actionContext,
                    elementId: node.id,
                    elementType: node.type.rawValue,
                    // Per-keystroke `onChange` emissions would flood analytics,
                    // and `onFocus` isn't a meaningful interaction kind for
                    // funnel analysis. Emit only on blur (treated as "the
                    // user finished editing this field"). The action chain
                    // itself still runs for all three events.
                    interactionType: event == .onBlur ? "change" : nil
                )
            }
        }
    }
}

// MARK: - Toggle View

/// Renders a toggle component as a platform Switch. The toggle is a primitive
/// that maps 1:1 to `SwitchToggleStyle`; a checkbox is composed as a Block
/// (stack + icon + text) rather than a structural variant, per
/// COMPONENT_OVERHAUL_PLAN.md §2.1A / §4.8.
struct ToggleView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext

    @State private var isOn: Bool = false

    var body: some View {
        HStack {
            if let label = resolvedLabel {
                Text(label)
                    .foregroundColor(.primary)
                Spacer()
            }

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: resolvedActiveColor))
                .labelsHidden()
        }
        .onAppear {
            isOn = PropertyResolver.resolve(node.props?.value, store: variableStore, default: false)
        }
        .onChange(of: isOn) { newValue in
            handleChange(newValue)
        }
    }

    // MARK: - Property Resolution

    private var resolvedLabel: String? {
        PropertyResolver.resolveString(node.props?.label, store: variableStore)
    }

    private var resolvedActiveColor: Color {
        let colorStr = PropertyResolver.resolve(node.props?.activeColor, store: variableStore, default: "#4F46E5")
        return Color(hex: colorStr) ?? .blue
    }

    // MARK: - Event Handlers

    private func handleChange(_ newValue: Bool) {
        if let interaction = findInteraction(event: .onChange) {
            Task {
                await actionExecutor.execute(
                    actions: interaction.actions,
                    context: actionContext,
                    elementId: node.id,
                    elementType: node.type.rawValue,
                    interactionType: "toggle"
                )
            }
        }
    }

    private func findInteraction(event: ComponentEventType) -> ComponentInteraction? {
        node.interactions?.first { $0.event == event }
    }
}
