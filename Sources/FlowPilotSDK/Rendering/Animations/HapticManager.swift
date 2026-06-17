import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Haptic Manager

/// Centralized haptic feedback manager with pre-allocated generators.
///
/// `HapticManager` is a singleton that pre-creates all `UIFeedbackGenerator` instances
/// at init time and keeps them alive for the lifetime of the app. This avoids the latency
/// penalty of allocating generators on-demand (which can cause a noticeable delay before
/// the first haptic fires).
///
/// **Thread Safety**: All public methods dispatch to the main queue because
/// `UIFeedbackGenerator` must be used from the main thread.
///
/// **Usage**:
/// ```swift
/// // Prepare generators (call when a screen begins loading)
/// HapticManager.shared.prepare()
///
/// // Fire a single haptic immediately
/// HapticManager.shared.fire("medium")
///
/// // Fire a haptic after a delay
/// HapticManager.shared.fire("selection", after: 0.3)
///
/// // Schedule stagger haptic ticks at each child's appearance time
/// HapticManager.shared.scheduleStaggerTicks(
///     pattern: "tick",
///     times: [0.0, 0.08, 0.16, 0.24, 0.32]
/// )
/// ```
///
/// **Supported haptic types**:
/// - Impact: `"light"`, `"medium"`, `"heavy"`, `"rigid"`, `"soft"`
/// - Notification: `"success"`, `"warning"`, `"error"`
/// - Selection: `"selection"`
/// - No-op: `"none"` (silently ignored)
final class HapticManager: @unchecked Sendable {

    /// Shared singleton instance.
    static let shared = HapticManager()

    #if canImport(UIKit)
    // Pre-allocated impact feedback generators, keyed by style name.
    private let impactGenerators: [String: UIImpactFeedbackGenerator]

    // Pre-allocated notification feedback generator.
    private let notificationGenerator: UINotificationFeedbackGenerator

    // Pre-allocated selection feedback generator.
    private let selectionGenerator: UISelectionFeedbackGenerator
    #endif

    private init() {
        #if canImport(UIKit)
        impactGenerators = [
            "light": UIImpactFeedbackGenerator(style: .light),
            "medium": UIImpactFeedbackGenerator(style: .medium),
            "heavy": UIImpactFeedbackGenerator(style: .heavy),
            "rigid": UIImpactFeedbackGenerator(style: .rigid),
            "soft": UIImpactFeedbackGenerator(style: .soft),
        ]
        notificationGenerator = UINotificationFeedbackGenerator()
        selectionGenerator = UISelectionFeedbackGenerator()
        #endif
    }

    // MARK: - Prepare

    /// Prepares all feedback generators so they fire without latency.
    ///
    /// Call this when a new screen begins loading to warm up the Taptic Engine.
    /// Preparing a generator that is already prepared is a no-op on the system side.
    func prepare() {
        #if canImport(UIKit)
        DispatchQueue.main.async { [self] in
            impactGenerators.values.forEach { $0.prepare() }
            notificationGenerator.prepare()
            selectionGenerator.prepare()
        }
        #endif
    }

    // MARK: - Fire

    /// Fires a single haptic feedback of the given type.
    ///
    /// - Parameters:
    ///   - type: The haptic type string matching the schema values.
    ///     One of: `"light"`, `"medium"`, `"heavy"`, `"rigid"`, `"soft"`,
    ///     `"success"`, `"warning"`, `"error"`, `"selection"`, or `"none"`.
    ///   - delay: Time interval in seconds to wait before firing. Defaults to 0 (immediate).
    func fire(_ type: String, after delay: TimeInterval = 0) {
        guard type != "none" else { return }

        #if canImport(UIKit)
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                self.fireOnMain(type)
            }
        } else {
            DispatchQueue.main.async { [self] in
                self.fireOnMain(type)
            }
        }
        #endif
    }

    // MARK: - Stagger Scheduling

    /// Schedules a sequence of haptic ticks at explicit per-child appearance times.
    ///
    /// Each entry in `times` is the number of seconds from now at which the
    /// corresponding child becomes visible. The caller is responsible for
    /// computing these to match the animation timing — they already fold in the
    /// stagger interval, the cascade of earlier siblings' enter delays, and the
    /// child's own enter delay — so a delayed child gets its tick when it
    /// actually appears rather than at a uniform `index * interval` cadence.
    ///
    /// - Parameters:
    ///   - pattern: The stagger haptic pattern.
    ///     - `"tick"`: Fires a `selection` haptic for each child.
    ///     - `"ramp"`: Fires escalating intensity (`light` -> `medium` -> `heavy`).
    ///     - `"none"` or other: No haptics scheduled.
    ///   - times: Per-child fire times in seconds, **sorted ascending** so the
    ///     `ramp` pattern escalates intensity in appearance order.
    func scheduleStaggerTicks(pattern: String, times: [TimeInterval]) {
        guard pattern != "none", !times.isEmpty else { return }

        #if canImport(UIKit)
        // Prepare generators before the sequence starts
        prepare()

        let count = times.count
        for (i, time) in times.enumerated() {
            switch pattern {
            case "tick":
                fire("selection", after: time)

            case "ramp":
                // Escalate intensity across thirds of the sequence:
                // first third -> light, middle third -> medium, last third -> heavy
                let hapticType: String
                if i < count / 3 {
                    hapticType = "light"
                } else if i < (count * 2) / 3 {
                    hapticType = "medium"
                } else {
                    hapticType = "heavy"
                }
                fire(hapticType, after: time)

            default:
                break
            }
        }
        #endif
    }

    // MARK: - Private

    #if canImport(UIKit)
    /// Fires the haptic on the main thread. Must be called from the main queue.
    private func fireOnMain(_ type: String) {
        switch type {
        case "light", "medium", "heavy", "rigid", "soft":
            impactGenerators[type]?.impactOccurred()

        case "success":
            notificationGenerator.notificationOccurred(.success)

        case "warning":
            notificationGenerator.notificationOccurred(.warning)

        case "error":
            notificationGenerator.notificationOccurred(.error)

        case "selection":
            selectionGenerator.selectionChanged()

        default:
            Logger.shared.debug("[HapticManager] Unknown haptic type: \(type)")
        }
    }
    #endif
}
