import Foundation

// MARK: - Stagger Coordinator

/// Computes resolved stagger indices for children based on the configured stagger order.
///
/// When a parent container has `staggerChildren: true`, each child receives a
/// logical stagger index that determines its animation delay. The index is computed
/// from the child's natural position and the parent's `staggerOrder` property:
///
/// - **natural**: Children animate in DOM order (index 0, 1, 2, ...).
/// - **reverse**: Last child animates first (index = total - 1 - naturalIndex).
/// - **center-out**: Center children animate first, edges last.
/// - **random**: A deterministic pseudo-random order based on position (reproducible across renders).
struct StaggerCoordinator {

    /// Resolves the effective stagger index for a child at the given natural position.
    ///
    /// The resolved index is used to compute the animation delay:
    /// `effectiveDelay = animDelay + (resolvedIndex * staggerInterval)`
    ///
    /// - Parameters:
    ///   - index: The child's natural (DOM-order) index, starting at 0.
    ///   - order: The stagger order string from the parent's `staggerOrder` property.
    ///   - total: The total number of children participating in the stagger sequence.
    /// - Returns: The resolved index used for delay computation. Lower indices animate earlier.
    static func resolvedIndex(_ index: Int, order: String, total: Int) -> Int {
        guard total > 0 else { return 0 }

        switch order {
        case "reverse":
            return total - 1 - index

        case "center-out":
            // Children closest to the center get the lowest index (animate first),
            // edges get the highest index (animate last).
            let center = total / 2
            return abs(index - center)

        case "random":
            // Deterministic shuffle: maps each natural index to a pseudo-random
            // position using a simple linear congruential formula. This ensures
            // the order is stable across re-renders (no actual randomness).
            return deterministicShuffle(index, total: total)

        default:
            // "natural" and any unrecognized value
            return index
        }
    }

    /// The child's enter delay in seconds — how long after appearing before its
    /// enter animation starts. Reads the new timeline encoding (a leading
    /// zero-duration `onAppear` anchor + an `afterPrevious` gap) and falls back
    /// to the legacy animation config's delay. Returns 0 when there is no
    /// on-appear delay (e.g. tap-triggered animations).
    static func enterDelay(for child: ComponentNode, variableStore: VariableStore) -> TimeInterval {
        if let timeline = AnimationTimeline.resolve(from: child.props, variableStore: variableStore),
           !timeline.steps.isEmpty {
            let steps = timeline.steps
            if steps.count >= 2,
               case .onAppear = steps[0].trigger,
               steps[0].duration == 0,
               case .afterPrevious(let gap) = steps[1].trigger {
                return gap
            }
            return 0
        }
        if let config = AnimationConfig.resolve(from: child.props, variableStore: variableStore),
           config.trigger == "appear" {
            return config.delay
        }
        return 0
    }

    /// Cumulative "prior delay" (seconds) per child for cascade-correct stagger:
    /// each child carries the sum of the enter delays of every earlier-staggered
    /// sibling, so a delayed child pushes the ones after it instead of being
    /// overtaken. Keyed by child id; all zero when no child has an enter delay.
    static func priorDelays(
        children: [ComponentNode],
        order: String,
        variableStore: VariableStore
    ) -> [String: TimeInterval] {
        let total = children.count
        let entries = children.enumerated()
            .map { (index, child) -> (pos: Int, id: String, delay: TimeInterval) in
                (resolvedIndex(index, order: order, total: total),
                 child.id,
                 enterDelay(for: child, variableStore: variableStore))
            }
            .sorted { $0.pos < $1.pos }

        var result: [String: TimeInterval] = [:]
        var cumulative: TimeInterval = 0
        for entry in entries {
            result[entry.id] = cumulative
            cumulative += entry.delay
        }
        return result
    }

    // MARK: - Private

    /// Produces a deterministic pseudo-random mapping from `index` to a value in `0..<total`.
    ///
    /// Uses a simple linear congruential generator (LCG) approach with constants chosen
    /// to produce a reasonable spread for small totals (typically <= 30 children).
    /// The multiplier 7 and offset 3 are coprime with most small totals, producing
    /// a full-cycle permutation for many values of `total`.
    private static func deterministicShuffle(_ index: Int, total: Int) -> Int {
        guard total > 1 else { return 0 }
        return (index * 7 + 3) % total
    }
}
