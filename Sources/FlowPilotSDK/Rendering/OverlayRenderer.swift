import SwiftUI

// MARK: - Overlay Renderer

/// Renders the overlay zone — a persistent floating layer on top of the content area.
///
/// Unlike navigationBar/footer which occupy layout space in the VStack,
/// the overlay is rendered as a ZStack layer over the content area.
/// It does NOT push content down or up.
@MainActor
struct OverlayRenderer: View {
    let overlay: OverlayZone
    let screenSettings: ZoneScreenOverride?
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let iconBaseUrl: String?
    var renderTrigger: Int = 0

    var body: some View {
        if isVisible {
            badge
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: resolvedAlignment)
                .allowsHitTesting(!(overlay.props?.passthrough ?? false))
        }
    }

    /// The overlay's root component. An overlay is a floating, positioned layer,
    /// so a `width: "auto"` root must **hug its content** (CSS shrink-to-fit for a
    /// positioned box) rather than expand to the block-level default of 100%.
    /// Without this, the auto-width badge fills the whole overlay frame and the
    /// `resolvedAlignment` anchor (e.g. `topTrailing`) has nothing to push to one
    /// side. `fixedSize(horizontal:)` makes it size to its content; an explicit
    /// fixed/percent width is honored as-is.
    @ViewBuilder
    private var badge: some View {
        let renderer = ComponentRenderer(
            node: overlay.layout,
            variableStore: variableStore,
            actionExecutor: actionExecutor,
            actionContext: actionContext,
            mediaBaseUrl: nil,
            iconBaseUrl: iconBaseUrl,
            renderTrigger: renderTrigger
        )
        if rootHugsWidth {
            renderer.fixedSize(horizontal: true, vertical: false)
        } else {
            renderer
        }
    }

    /// Whether the overlay root should hug its content width (auto / unset width).
    private var rootHugsWidth: Bool {
        switch overlay.layout.props?.width {
        case nil, .auto: return true
        default: return false
        }
    }

    private var isVisible: Bool {
        screenSettings?.visible ?? true
    }

    private var resolvedAlignment: Alignment {
        switch overlay.props?.alignment ?? "bottomTrailing" {
        case "topLeading": return .topLeading
        case "top": return .top
        case "topTrailing": return .topTrailing
        case "leading": return .leading
        case "center": return .center
        case "trailing": return .trailing
        case "bottomLeading": return .bottomLeading
        case "bottom": return .bottom
        case "bottomTrailing": return .bottomTrailing
        default: return .bottomTrailing
        }
    }
}
