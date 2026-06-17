import Foundation

/// Resolves which TransitionConfig to use for a given screen navigation,
/// implementing the 3-level cascade: Edge → Screen → Flow → Platform Default.
struct TransitionResolver {

    // MARK: - Platform Default

    static let platformDefault = TransitionConfig(
        type: "slideFromRight",
        duration: 300,
        easing: "easeInOut"
    )

    // MARK: - Forward Resolution

    /// Resolve transition for forward navigation.
    /// Cascade: edge → destination.enterTransition → source.exitTransition → flowSettings.defaultTransition → platform default
    static func resolveForward(
        edge: FlowEdge?,
        destination: ScreenNode?,
        source: ScreenNode?,
        flowSettings: FlowSettings?
    ) -> TransitionConfig {
        if let t = edge?.transition { return t }
        if let t = destination?.enterTransition { return t }
        if let t = source?.exitTransition { return t }
        if let t = flowSettings?.defaultTransition { return t }
        return platformDefault
    }

    // MARK: - Back Resolution

    /// Resolve transition for back navigation.
    /// Cascade: destination.enterTransition → source.exitTransition → flowSettings.backTransition → autoReverse(forward)
    static func resolveBack(
        originalForwardEdge: FlowEdge?,
        destination: ScreenNode?,
        source: ScreenNode?,
        flowSettings: FlowSettings?
    ) -> TransitionConfig {
        if let t = destination?.enterTransition { return t }
        if let t = source?.exitTransition { return t }
        if let t = flowSettings?.backTransition { return t }

        // Auto-reverse the forward transition
        let forward = resolveForward(
            edge: originalForwardEdge,
            destination: source,       // swapped: source of back = destination of forward
            source: destination,        // swapped: destination of back = source of forward
            flowSettings: flowSettings
        )
        return autoReverse(forward)
    }

    // MARK: - Combined Resolution

    /// Resolve transition using NavigationTransitionInfo (convenience).
    /// - Parameters:
    ///   - transitionInfo: The navigation transition metadata.
    ///   - flowSettings: The flow-level settings.
    ///   - reverseEdgeLookup: Optional closure to find a reverse edge (destination→source).
    static func resolve(
        transitionInfo: NavigationTransitionInfo?,
        flowSettings: FlowSettings?,
        reverseEdgeLookup: ((String, String) -> FlowEdge?)? = nil
    ) -> TransitionConfig {
        guard let info = transitionInfo else { return platformDefault }

        if info.isBack {
            // Check for explicit reverse edge transition
            if let lookup = reverseEdgeLookup,
               let destId = info.destinationScreen?.id,
               let srcId = info.sourceScreen?.id {
                if let reverseEdge = lookup(destId, srcId),
                   let t = reverseEdge.transition {
                    return t
                }
            }

            return resolveBack(
                originalForwardEdge: info.traversedEdge,
                destination: info.destinationScreen,
                source: info.sourceScreen,
                flowSettings: flowSettings
            )
        } else {
            return resolveForward(
                edge: info.traversedEdge,
                destination: info.destinationScreen,
                source: info.sourceScreen,
                flowSettings: flowSettings
            )
        }
    }

    // MARK: - Auto-Reverse

    private static let reverseMap: [TransitionType: TransitionType] = [
        .none: .none,
        .fade: .fade,
        .slideFromRight: .slideFromLeft,
        .slideFromLeft: .slideFromRight,
        .slideFromBottom: .slideFromTop,
        .slideFromTop: .slideFromBottom,
        .push: .push,
        .scale: .scale,
        .flip: .flip,
    ]

    static func autoReverse(_ config: TransitionConfig) -> TransitionConfig {
        let reversedType = reverseMap[config.resolvedType] ?? config.resolvedType
        return TransitionConfig(
            type: reversedType.rawValue,
            duration: config.duration,
            easing: config.easing,
            springDamping: config.springDamping,
            springResponse: config.springResponse,
            durationMs: config.durationMs
        )
    }
}
