import Foundation

// MARK: - Flow Delivery Source

/// How a presented flow's definition was obtained.
///
/// Surfaced on automatic analytics events as `delivery_source` so offline /
/// fallback renders are distinguishable from live network resolves in the
/// dashboard. Part of the SDK's fail-safe story: even when FlowPilot serves a
/// degraded experience (stale cache, bundled default), the dashboard can tell.
public enum FlowDeliverySource: String, Sendable {
    /// Resolved fresh from the FlowPilot resolve API.
    case network

    /// Served from a still-fresh local cache entry (no network round-trip).
    case cache

    /// Served from the last-known-good cache because the live resolve failed
    /// or exceeded the hard timeout.
    case staleCache = "stale_cache"

    /// Served from a flow JSON bundled into the app at build time.
    case bundledDefault = "bundled_default"
}

// MARK: - Presentability Validation

extension ResolvedFlow {
    /// Whether this flow can actually be presented.
    ///
    /// A flow is presentable only if it has at least one screen node and an
    /// entry node the navigation graph can resolve. This catches the
    /// "all screens were dropped during lenient decode" and "entry node is
    /// missing" cases *before* presentation, so such a flow falls through to
    /// the next fallback tier instead of stranding the user on the loading
    /// spinner (`FlowPresenterView` shows "Loading…" whenever no screen has
    /// been displayed yet).
    func validateForPresentation() -> Bool {
        let nodes = definition.nodes
        guard !nodes.isEmpty else {
            Logger.shared.warn("Flow \(flowId) not presentable: no nodes")
            return false
        }

        let hasScreen = nodes.contains { node in
            if case .screen = node { return true }
            return false
        }
        guard hasScreen else {
            Logger.shared.warn("Flow \(flowId) not presentable: no screen nodes")
            return false
        }

        let entry = definition.entryNodeId
        guard !entry.isEmpty, nodes.contains(where: { $0.id == entry }) else {
            Logger.shared.warn("Flow \(flowId) not presentable: entry node '\(entry)' is missing")
            return false
        }

        return true
    }
}
