import SwiftUI
import Combine

// MARK: - Component Renderer

/// Renders ComponentNode trees as SwiftUI views
@MainActor
struct ComponentRenderer: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let mediaBaseUrl: String?
    let iconBaseUrl: String?
    let renderTrigger: Int

    @Environment(\.animationSpeedMultiplier) private var animationSpeed
    @Environment(\.flowGlobalStyles) private var flowGlobalStyles

    @State private var cancellables = Set<AnyCancellable>()

    init(
        node: ComponentNode,
        variableStore: VariableStore,
        actionExecutor: ActionExecutor,
        actionContext: ActionContext,
        mediaBaseUrl: String?,
        iconBaseUrl: String? = nil,
        renderTrigger: Int = 0
    ) {
        self.node = node
        self.variableStore = variableStore
        self.actionExecutor = actionExecutor
        self.actionContext = actionContext
        self.mediaBaseUrl = mediaBaseUrl
        self.iconBaseUrl = iconBaseUrl
        self.renderTrigger = renderTrigger
    }

    public var body: some View {
        // renderTrigger is used to force re-render when variables change
        let _ = renderTrigger
        let _ = Logger.shared.debug("ComponentRenderer.body - rendering node type: \(node.type.rawValue), children count: \(node.children?.count ?? 0)")
        renderComponent(node)
    }

    // MARK: - Component Dispatch

    @ViewBuilder
    private func renderComponent(_ node: ComponentNode) -> some View {
        let isVisible = resolveProperty(node.props?.isVisible, default: true)

        if isVisible {
            let visibility = resolveProperty(node.props?.visibility, default: "visible")
            let isHidden = visibility == "hidden"
            let isDisabled = resolveProperty(node.props?.disabled, default: false)
            let disabledOpacity: Double = (isDisabled && node.props?.opacity == nil) ? 0.5 : 1.0

            componentView(for: node)
                .modifier(UniversalStyleModifier(
                    props: universalStyleProps(for: node),
                    variableStore: variableStore,
                    renderTrigger: renderTrigger
                ))
                .modifier(StepAnimator(
                    props: node.props,
                    variableStore: variableStore,
                    animationSpeed: animationSpeed,
                    componentId: node.id
                ))
                .modifier(PressModifier(
                    config: isDisabled ? nil : PressFeedbackConfig.resolve(from: node.props)
                ))
                .modifier(InteractionModifier(
                    node: node,
                    actionExecutor: actionExecutor,
                    actionContext: actionContext,
                    isDisabled: isDisabled
                ))
                .opacity(isHidden ? 0 : disabledOpacity)
                .allowsHitTesting(!isHidden && !isDisabled)
        }
    }

    @ViewBuilder
    private func componentView(for node: ComponentNode) -> some View {
        switch node.type {
        case .screenRoot:
            ScreenRootView(
                node: node,
                variableStore: variableStore,
                actionExecutor: actionExecutor,
                actionContext: actionContext,
                mediaBaseUrl: mediaBaseUrl,
                iconBaseUrl: iconBaseUrl,
                renderTrigger: renderTrigger
            )

        case .stack:
            StackView(
                node: node,
                variableStore: variableStore,
                actionExecutor: actionExecutor,
                actionContext: actionContext,
                mediaBaseUrl: mediaBaseUrl,
                iconBaseUrl: iconBaseUrl,
                renderTrigger: renderTrigger
            )

        case .text:
            TextView(props: node.props, variableStore: variableStore, renderTrigger: renderTrigger)

        case .image:
            ImageView(props: node.props, variableStore: variableStore, mediaBaseUrl: mediaBaseUrl)

        case .button:
            ButtonView(
                node: node,
                variableStore: variableStore,
                actionExecutor: actionExecutor,
                actionContext: actionContext,
                mediaBaseUrl: mediaBaseUrl,
                iconBaseUrl: iconBaseUrl,
                renderTrigger: renderTrigger
            )

        case .input:
            InputView(node: node, variableStore: variableStore, actionExecutor: actionExecutor, actionContext: actionContext, renderTrigger: renderTrigger)

        case .toggle:
            ToggleView(node: node, variableStore: variableStore, actionExecutor: actionExecutor, actionContext: actionContext)

        case .progress:
            ProgressBarView(node: node, variableStore: variableStore, actionExecutor: actionExecutor, actionContext: actionContext, renderTrigger: renderTrigger)

        case .ringProgress:
            RingProgressView(
                node: node,
                variableStore: variableStore,
                actionExecutor: actionExecutor,
                actionContext: actionContext,
                mediaBaseUrl: mediaBaseUrl,
                iconBaseUrl: iconBaseUrl,
                renderTrigger: renderTrigger
            )

        case .slider:
            SliderView(node: node, variableStore: variableStore, actionExecutor: actionExecutor, actionContext: actionContext, renderTrigger: renderTrigger)

        case .picker:
            PickerView(node: node, variableStore: variableStore, actionExecutor: actionExecutor, actionContext: actionContext, renderTrigger: renderTrigger)

        case .ruler:
            RulerView(node: node, variableStore: variableStore, actionExecutor: actionExecutor, actionContext: actionContext, renderTrigger: renderTrigger)

        case .lottie:
            LottieView(props: node.props, variableStore: variableStore, mediaBaseUrl: mediaBaseUrl)

        case .comparisonChart:
            ComparisonChartView(node: node, variableStore: variableStore, renderTrigger: renderTrigger)

        case .icon:
            IconView(props: node.props, variableStore: variableStore, iconBaseUrl: iconBaseUrl, renderTrigger: renderTrigger)

        case .custom:
            // Custom component rendering
            CustomComponentView(
                node: node,
                variableStore: variableStore,
                actionExecutor: actionExecutor,
                actionContext: actionContext
            )

        case .unknown:
            // A component type this SDK build doesn't recognize (e.g. shipped by a
            // newer flow). Degrade gracefully: render nothing in production so the
            // rest of the screen still works; show a placeholder while debugging.
            #if DEBUG
            PlaceholderView(type: "unknown: \(node.id)")
            #else
            EmptyView()
            #endif
        }
    }

    // MARK: - Helpers

    /// Props passed to `UniversalStyleModifier`. For buttons, variant-derived
    /// background/border defaults are merged in so the universal pass paints them
    /// on the padded, clipped frame — keeping button styling unified with stack
    /// (overhaul §2.2). The button's content view itself stays style-free.
    private func universalStyleProps(for node: ComponentNode) -> ComponentProps? {
        guard node.type == .button else { return node.props }
        let variant = ButtonVariant.from(
            PropertyResolver.resolve(node.props?.variant, store: variableStore)
        )
        let defaults = buttonVariantDefaultProps(variant, globalStyles: flowGlobalStyles)
        if defaults.isEmpty { return node.props }
        if let props = node.props { return props.merging(defaults: defaults) }
        return ComponentProps(rawProps: defaults)
    }

    private func resolveProperty<T>(_ property: PropertyValue<T>?, default defaultValue: T) -> T {
        PropertyResolver.resolve(property, store: variableStore, default: defaultValue)
    }
}

// MARK: - Placeholder View

struct PlaceholderView: View {
    let type: String

    var body: some View {
        Text("[\(type)]")
            .foregroundColor(.gray)
            .font(.caption)
    }
}
