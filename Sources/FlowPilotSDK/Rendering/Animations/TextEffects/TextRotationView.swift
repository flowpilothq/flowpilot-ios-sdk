import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Text Rotation View

/// Cycles through an array of text values with configurable transitions.
///
/// Matches the editor's `textRotation` feature. The first value in the array is
/// typically the component's own content; subsequent values come from
/// `textRotation.values`.
///
/// Supported transitions:
/// - `"slideUp"`: new text slides in from bottom, old text slides out to top.
/// - `"slideDown"`: new text slides in from top, old text slides out to bottom.
/// - `"fadeThrough"` / `"crossFade"`: simple opacity cross-fade.
/// - `"flip"`: scale + opacity combination.
/// - `"scramble"`: uses opacity for simplicity (matches editor behavior).
///
/// The view uses `.id(currentIndex)` on the text to trigger SwiftUI transitions
/// when the value changes.
///
/// Respects `UIAccessibility.isReduceMotionEnabled` -- when active, only the
/// first value is shown with no cycling.
struct TextRotationView: View {

    /// All values to cycle through (component content + rotation values).
    let values: [String]

    /// Milliseconds between value changes.
    let interval: Double

    /// Transition type name.
    let transition: String

    /// Transition animation duration in milliseconds.
    let transitionDuration: Double

    /// Whether to loop back to the first value after reaching the end.
    let loop: Bool

    /// Whether to stop cycling once the last value is reached.
    let pauseOnLast: Bool

    // MARK: - State

    /// Index of the currently displayed value.
    @State private var currentIndex: Int = 0

    /// Active cycling timer.
    @State private var cycleTimer: Timer?

    // MARK: - Derived

    /// The currently displayed text value.
    private var currentText: String {
        guard !values.isEmpty else { return "" }
        return values[currentIndex % values.count]
    }

    /// The resolved SwiftUI transition for insertions and removals.
    private var resolvedTransition: AnyTransition {
        switch transition {
        case "slideUp":
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )

        case "slideDown":
            return .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .bottom).combined(with: .opacity)
            )

        case "fadeThrough", "crossFade", "scramble":
            return .opacity

        case "flip":
            return .scale.combined(with: .opacity)

        default:
            return .opacity
        }
    }

    /// The transition animation.
    private var transitionAnimation: Animation {
        let duration = transitionDuration / 1000.0
        return .easeInOut(duration: duration)
    }

    // MARK: - Body

    var body: some View {
        if isReduceMotionEnabled || values.isEmpty {
            // Show first value only when Reduce Motion is enabled.
            Text(values.first ?? "")
        } else {
            Text(currentText)
                .id(currentIndex)
                .transition(resolvedTransition)
                .animation(transitionAnimation, value: currentIndex)
                .onAppear {
                    startCycling()
                }
                .onDisappear {
                    stopCycling()
                }
        }
    }

    // MARK: - Timer Management

    /// Starts the cycling timer.
    private func startCycling() {
        guard values.count > 1 else { return }

        let intervalSeconds = interval / 1000.0
        let timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { _ in
            advanceToNext()
        }
        cycleTimer = timer
    }

    /// Advances to the next value in the rotation.
    private func advanceToNext() {
        let nextIndex = currentIndex + 1

        if nextIndex >= values.count {
            if pauseOnLast {
                // Stop at the last value.
                stopCycling()
                return
            }
            if loop {
                withAnimation(transitionAnimation) {
                    currentIndex = 0
                }
            } else {
                stopCycling()
            }
        } else {
            withAnimation(transitionAnimation) {
                currentIndex = nextIndex
            }
        }
    }

    /// Stops the cycling timer.
    private func stopCycling() {
        cycleTimer?.invalidate()
        cycleTimer = nil
    }

    // MARK: - Accessibility

    /// Whether the system's Reduce Motion accessibility setting is enabled.
    private var isReduceMotionEnabled: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }
}
