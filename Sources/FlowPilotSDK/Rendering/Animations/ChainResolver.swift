import Foundation

// MARK: - Chain Resolver

/// Computes chain delays for all children of a container.
///
/// Children with `chainAfterPrevious: true` start after the previous
/// animated sibling's animation finishes (effectiveDelay + duration).
/// The returned delay already includes the component's own delay.
struct ChainResolver {

    /// Computes chain delays for all children of a container.
    ///
    /// - Parameters:
    ///   - children: The child nodes of the container.
    ///   - variableStore: Variable store for resolving conditional props.
    /// - Returns: Dictionary mapping child ID to chain delay in seconds.
    static func resolveChainDelays(
        children: [ComponentNode],
        variableStore: VariableStore
    ) -> [String: TimeInterval] {
        var delays: [String: TimeInterval] = [:]
        var previousEnd: TimeInterval = 0
        var hasPreviousAnimation = false

        for child in children {
            guard let config = AnimationConfig.resolve(from: child.props, variableStore: variableStore),
                  config.trigger != "none" else {
                delays[child.id] = 0
                continue
            }

            let duration = config.duration
            let ownDelay = config.delay

            if config.chainAfterPrevious && hasPreviousAnimation {
                let chainDelay = previousEnd + ownDelay
                delays[child.id] = chainDelay
                previousEnd = chainDelay + duration
            } else {
                delays[child.id] = ownDelay
                previousEnd = ownDelay + duration
            }

            hasPreviousAnimation = true
        }

        return delays
    }
}
