import SwiftUI

// MARK: - Stagger Context

/// Carries stagger information from a parent container down to its children
/// via the SwiftUI environment.
///
/// When a parent stack has `staggerChildren: true`, it injects a `StaggerContext`
/// with each child's resolved index and the interval. `AnimationModifier` reads
/// this from the environment to compute the effective delay.
struct StaggerContext: Equatable {
    /// The resolved stagger index for this child (0 = animates first).
    let index: Int

    /// The interval in seconds between each child's animation start.
    let interval: TimeInterval

    /// Computed chain delay in seconds (already includes own delay when > 0).
    let chainDelay: TimeInterval

    /// Cascade offset in seconds: the sum of the enter delays of all
    /// earlier-staggered siblings. Added to `index * interval` so a delayed
    /// sibling pushes the ones after it instead of being overtaken (the child
    /// still applies its own enter delay on top). 0 when no earlier sibling is
    /// delayed.
    let priorDelay: TimeInterval

    /// Default context indicating no stagger or chain is active.
    static let none = StaggerContext(index: 0, interval: 0, chainDelay: 0, priorDelay: 0)

    /// Whether stagger or chain is active.
    var isActive: Bool {
        interval > 0 || chainDelay > 0 || priorDelay > 0
    }
}

// MARK: - Environment Key

/// Environment key for passing stagger context from parent containers to children.
struct StaggerContextKey: EnvironmentKey {
    static let defaultValue: StaggerContext = .none
}

extension EnvironmentValues {
    /// The stagger context injected by the nearest parent stagger container.
    ///
    /// Children read this to determine their stagger index and interval,
    /// which `AnimationModifier` uses to compute the effective animation delay.
    var staggerContext: StaggerContext {
        get { self[StaggerContextKey.self] }
        set { self[StaggerContextKey.self] = newValue }
    }

}

// MARK: - Timeline Delays Environment Key

/// Holds the resolved timeline delays for all components on the current screen.
/// Key = componentId, Value = delay in seconds.
struct TimelineDelaysKey: EnvironmentKey {
    static let defaultValue: [String: TimeInterval] = [:]
}

extension EnvironmentValues {
    /// The resolved timeline delays for all timeline-controlled components.
    /// Injected at the screen level, read by `StepAnimator` per component.
    var timelineDelays: [String: TimeInterval] {
        get { self[TimelineDelaysKey.self] }
        set { self[TimelineDelaysKey.self] = newValue }
    }
}
