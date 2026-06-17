import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Scramble Effect View

/// Reveals text by progressively "settling" random characters from left to right.
///
/// Matches the editor's `scramble` text effect. Initially, all characters are
/// replaced with random glyphs from a configurable character set. Over time,
/// characters lock into their correct values from left to right, creating a
/// decode/unscramble visual effect.
///
/// The reveal speed is controlled by the `speed` parameter (chars/sec).
///
/// Respects `UIAccessibility.isReduceMotionEnabled` -- when active, the final
/// text is shown immediately with no animation.
struct ScrambleEffectView: View {

    /// The target text to reveal.
    let targetText: String

    /// Characters per second for the settle rate.
    let speed: Double

    /// Delay in milliseconds before the effect starts.
    let delay: Double

    // MARK: - State

    /// Number of characters that have settled into their correct value (from left).
    @State private var settledCount: Int = 0

    /// The currently displayed scrambled string.
    @State private var displayText: String = ""

    /// Timer driving the scramble animation.
    @State private var scrambleTimer: Timer?

    /// Whether the effect has completed.
    @State private var isComplete: Bool = false

    // MARK: - Constants

    /// Character set used for scrambled (unsettled) positions.
    private static let scrambleChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%&*")

    // MARK: - Body

    var body: some View {
        if isReduceMotionEnabled {
            Text(targetText)
        } else {
            Text(displayText.isEmpty ? buildScrambledText() : displayText)
                .onAppear {
                    startEffect()
                }
                .onDisappear {
                    invalidateTimer()
                }
        }
    }

    // MARK: - Scramble Logic

    /// Builds the display text with settled characters on the left and random characters on the right.
    private func buildScrambledText() -> String {
        let chars = Array(targetText)
        var result = ""

        for i in 0..<chars.count {
            if i < settledCount {
                // This character has settled -- show the real character.
                result.append(chars[i])
            } else {
                // Unsettled -- show a random character, but preserve whitespace.
                if chars[i].isWhitespace {
                    result.append(chars[i])
                } else {
                    let randomChar = Self.scrambleChars.randomElement() ?? Character("X")
                    result.append(randomChar)
                }
            }
        }

        return result
    }

    /// Starts the scramble effect after the configured delay.
    private func startEffect() {
        guard !isComplete else { return }

        // Initialize display with fully scrambled text.
        displayText = buildScrambledText()

        let delaySeconds = delay / 1000.0

        // The settle interval is how often a new character locks in.
        let settleInterval = speed > 0 ? (1.0 / speed) : 0.025

        // The scramble refresh interval randomizes unsettled characters more frequently
        // for a more dynamic visual effect.
        let refreshInterval = min(settleInterval / 3.0, 0.03)

        var tickCount = 0
        let ticksPerSettle = max(1, Int(settleInterval / refreshInterval))

        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
            let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
                tickCount += 1

                // Settle one more character at the appropriate interval.
                if tickCount % ticksPerSettle == 0 && settledCount < targetText.count {
                    settledCount += 1
                }

                // Refresh the display text (randomize unsettled positions).
                displayText = buildScrambledText()

                // Check completion.
                if settledCount >= targetText.count {
                    displayText = targetText
                    isComplete = true
                    invalidateTimer()
                }
            }
            scrambleTimer = timer
        }
    }

    /// Invalidates the scramble timer.
    private func invalidateTimer() {
        scrambleTimer?.invalidate()
        scrambleTimer = nil
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
