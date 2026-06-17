import SwiftUI

// MARK: - Progress Bar View

/// Renders a progress bar component
struct ProgressBarView: View {
    let props: ComponentProps?
    let variableStore: VariableStore
    let navigationController: NavigationController
    var renderTrigger: Int = 0

    var body: some View {
        // Force re-evaluation when renderTrigger changes
        let _ = renderTrigger
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
