import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Fade-Per-Line Effect View

/// Splits text by newlines and fades in each line sequentially with a stagger delay.
///
/// Matches the editor's `fadePerLine` text effect. Each line starts invisible and
/// translates up slightly, then animates to full opacity and its resting position
/// with an ease-out curve. Lines are staggered so each subsequent line appears
/// after the previous one has begun its entrance.
///
/// The stagger interval is derived from the `speed` parameter:
/// `lineInterval = 1000 / (speed / 10)` ms. At the default speed of 40, this
/// gives ~250ms between each line's entrance.
///
/// Respects `UIAccessibility.isReduceMotionEnabled` -- when active, all lines
/// are shown immediately with no animation.
struct FadePerLineEffectView: View {

    /// The full text to render (may contain `\n` newlines).
    let fullText: String

    /// Characters per second, used to derive the per-line interval (legacy fallback).
    let speed: Double

    /// Delay in milliseconds before the first line starts fading in.
    let delay: Double

    /// Explicit line interval in milliseconds. If set, takes priority over speed-based derivation.
    let duration: Double?

    // MARK: - State

    /// Tracks which lines have been triggered to appear.
    @State private var visibleLines: Set<Int> = []

    /// Whether the animation sequence has started.
    @State private var hasStarted: Bool = false

    // MARK: - Derived

    /// The text split into individual lines.
    private var lines: [String] {
        fullText.components(separatedBy: "\n")
    }

    /// The interval (in seconds) between each line's fade-in start.
    private var lineInterval: Double {
        // Use explicit duration (in ms) if set, otherwise derive from speed
        if let duration = duration {
            return duration / 1000.0
        }
        let effectiveSpeed = max(speed, 1)
        return 1.0 / (effectiveSpeed / 10.0)
    }

    /// The duration (in seconds) of each line's fade-in animation.
    private var lineDuration: Double {
        lineInterval
    }

    // MARK: - Body

    var body: some View {
        if isReduceMotionEnabled {
            // Show all lines immediately when Reduce Motion is on.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line.isEmpty ? " " : line)
                        .opacity(visibleLines.contains(index) ? 1.0 : 0.0)
                        .offset(y: visibleLines.contains(index) ? 0 : 8)
                        .animation(
                            .easeOut(duration: lineDuration),
                            value: visibleLines.contains(index)
                        )
                }
            }
            .onAppear {
                startSequence()
            }
        }
    }

    // MARK: - Animation Sequence

    /// Triggers each line to fade in sequentially after the configured delay.
    private func startSequence() {
        guard !hasStarted else { return }
        hasStarted = true

        let initialDelay = delay / 1000.0

        for index in lines.indices {
            let lineDelay = initialDelay + Double(index) * lineInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + lineDelay) {
                visibleLines.insert(index)
            }
        }
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
