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
            ComponentRenderer(
                node: overlay.layout,
                variableStore: variableStore,
                actionExecutor: actionExecutor,
                actionContext: actionContext,
                mediaBaseUrl: nil,
                iconBaseUrl: iconBaseUrl,
                renderTrigger: renderTrigger
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: resolvedAlignment)
            .allowsHitTesting(!(overlay.props?.passthrough ?? false))
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
