import SwiftUI

// MARK: - Zone Renderer

/// Renders persistent zones (navigation bar / footer) with safe area management.
///
/// Handles the `safeArea` property from `ZoneProps` to prevent double-application
/// of safe area insets on iOS devices with home indicators or notches.
///
/// **Problem**: When the `UIHostingController` is presented full-screen, iOS
/// automatically applies safe area insets. The zone layout also carries explicit
/// padding from the JSON definition (e.g., 16px). These stack, producing
/// `safeAreaInset + explicitPadding` (e.g., 34 + 16 = 50px) instead of the
/// intended layout.
///
/// **Solution**: The caller (`FlowPresenterView`) applies `.ignoresSafeArea` on
/// the zone view to disable the system's automatic safe area padding. This
/// renderer then manually compensates based on the `safeArea` flag:
///
/// - `safeArea == true`: Adds `max(0, safeAreaInset - explicitPadding)` as
///   extra outer padding so the total equals `max(explicitPadding, safeAreaInset)`.
/// - `safeArea == false` or `nil`: No extra padding; only the explicit padding
///   from the JSON layout is used.
///
/// The `safeAreaInset` value is passed in from the parent view, which reads it
/// from a `GeometryReader` before safe area is ignored.
@MainActor
struct ZoneRenderer: View {
    let persistentUI: PersistentUI?
    let screenSettings: ScreenSettings?
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let position: ZonePosition
    let iconBaseUrl: String?
    var renderTrigger: Int = 0

    /// The device's safe area inset for the relevant edge, passed in by the
    /// parent before `.ignoresSafeArea` is applied.
    var safeAreaInset: CGFloat = 0

    enum ZonePosition {
        case navigationBar
        case footer
    }

    var body: some View {
        if let layout = resolveLayout() {
            let deltaPadding = safeAreaDeltaPadding(layout: layout)
            let _ = Logger.shared.debug("ZoneRenderer[\(position)] safeAreaInset=\(safeAreaInset), safeAreaEnabled=\(resolveSafeArea()), deltaPadding=\(deltaPadding)")

            ComponentRenderer(
                node: layout,
                variableStore: variableStore,
                actionExecutor: actionExecutor,
                actionContext: actionContext,
                mediaBaseUrl: nil,
                iconBaseUrl: iconBaseUrl,
                renderTrigger: renderTrigger
            )
            // Fill the available width, matching the screen-root content
            // (FlowPresenter applies `.frame(maxWidth: .infinity)` there). Without
            // this, the parent `.fixedSize(horizontal: false, vertical: true)`
            // lets the zone hug its content width, so a `width: 100%` button with
            // horizontal margins (which sizes via `.frame(maxWidth: .infinity)`)
            // collapses to its label width instead of spanning the zone.
            .frame(maxWidth: .infinity)
            .padding(relevantEdge, deltaPadding)
            .background(resolveEffectiveBackgroundColor(layout: layout))
        }
    }

    // MARK: - Safe Area Logic

    /// The SwiftUI edge set corresponding to this zone position.
    private var relevantEdge: Edge.Set {
        switch position {
        case .navigationBar: return .top
        case .footer: return .bottom
        }
    }

    /// Computes the additional padding needed on the relevant edge so that the
    /// total padding equals `max(explicitPadding, safeAreaInset)`.
    private func safeAreaDeltaPadding(layout: ComponentNode) -> CGFloat {
        guard resolveSafeArea() else {
            return 0
        }

        let explicitPadding: CGFloat
        switch position {
        case .navigationBar:
            explicitPadding = resolveExplicitPaddingTop(from: layout)
        case .footer:
            explicitPadding = resolveExplicitPaddingBottom(from: layout)
        }

        Logger.shared.debug("ZoneRenderer[\(position)] explicitPadding=\(explicitPadding), safeAreaInset=\(safeAreaInset)")
        return max(0, safeAreaInset - explicitPadding)
    }

    /// Reads the explicit top padding from the layout node's props.
    private func resolveExplicitPaddingTop(from layout: ComponentNode) -> CGFloat {
        if layout.props?.paddingAdvanced == true {
            if let top = layout.props?.paddingTop {
                return CGFloat(PropertyResolver.resolve(top, store: variableStore, default: 0))
            }
            return 0
        } else {
            if let vertical = layout.props?.paddingVertical {
                return CGFloat(PropertyResolver.resolve(vertical, store: variableStore, default: 0))
            }
            return 0
        }
    }

    /// Reads the explicit bottom padding from the layout node's props.
    private func resolveExplicitPaddingBottom(from layout: ComponentNode) -> CGFloat {
        if layout.props?.paddingAdvanced == true {
            if let bottom = layout.props?.paddingBottom {
                return CGFloat(PropertyResolver.resolve(bottom, store: variableStore, default: 0))
            }
            return 0
        } else {
            if let vertical = layout.props?.paddingVertical {
                return CGFloat(PropertyResolver.resolve(vertical, store: variableStore, default: 0))
            }
            return 0
        }
    }

    // MARK: - Resolution Logic

    private func resolveLayout() -> ComponentNode? {
        let zone: PersistentZone?
        let override: ZoneScreenOverride?

        switch position {
        case .navigationBar:
            zone = persistentUI?.navigationBar
            override = screenSettings?.navigationBar
        case .footer:
            zone = persistentUI?.footer
            override = screenSettings?.footer
        }

        // No zone defined
        guard let section = zone else {
            return nil
        }

        // Screen explicitly hides this zone
        if override?.visible == false {
            return nil
        }

        // Screen provides replacement layout
        if let replaceLayout = override?.replaceLayout {
            return Self.applyingComponentPropsPatches(replaceLayout, patches: override?.componentProps)
        }

        // Use zone layout if visible
        if section.visible {
            return Self.applyingComponentPropsPatches(section.layout, patches: override?.componentProps)
        }

        return nil
    }

    /// Shallow-merges the screen's per-component prop patches
    /// (`ZoneScreenOverride.componentProps`, keyed by component id) over the
    /// matching nodes of the zone layout — e.g. a required question writing a
    /// conditional `disabled` onto a shared continue button for one screen.
    private static func applyingComponentPropsPatches(
        _ node: ComponentNode,
        patches: [String: [String: AnyCodable]]?
    ) -> ComponentNode {
        guard let patches, !patches.isEmpty else { return node }
        let children = node.children?.map { applyingComponentPropsPatches($0, patches: patches) }
        let props: ComponentProps?
        if let patch = patches[node.id] {
            props = (node.props ?? ComponentProps(rawProps: [:])).merging(patch: patch)
        } else {
            props = node.props
        }
        return ComponentNode(
            id: node.id,
            type: node.type,
            props: props,
            children: children,
            interactions: node.interactions
        )
    }

    /// Resolves whether safe area handling is enabled for this zone.
    private func resolveSafeArea() -> Bool {
        let zone: PersistentZone?

        switch position {
        case .navigationBar:
            zone = persistentUI?.navigationBar
        case .footer:
            zone = persistentUI?.footer
        }

        return zone?.props?.safeArea == true
    }

    /// Resolves the background color for the safe area delta region.
    private func resolveEffectiveBackgroundColor(layout: ComponentNode) -> Color {
        // 1. Check zone-level background
        let zone: PersistentZone?
        switch position {
        case .navigationBar:
            zone = persistentUI?.navigationBar
        case .footer:
            zone = persistentUI?.footer
        }

        if let colorStr = zone?.props?.backgroundColor {
            return Color(hex: colorStr) ?? .clear
        }

        // 2. Fall back to the layout component's backgroundColor,
        //    but only if `fill` is not "none".
        let fill = PropertyResolver.resolve(layout.props?.fill, store: variableStore)
        if fill != "none", let bgProp = layout.props?.backgroundColor {
            let colorStr = PropertyResolver.resolve(bgProp, store: variableStore, default: "")
            if !colorStr.isEmpty {
                return Color(hex: colorStr) ?? .clear
            }
        }

        return .clear
    }
}
