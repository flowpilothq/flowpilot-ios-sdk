import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Typewriter Effect View

/// Reveals text character-by-character (or word-by-word) with an optional blinking cursor.
///
/// Designed to match the editor's `typewriter` and `typewriterWord` text effects.
///
/// - Character mode (`wordMode = false`): reveals one character per tick.
/// - Word mode (`wordMode = true`): reveals one whitespace-delimited word per tick.
///
/// The cursor is rendered inline after the currently visible text and can be
/// hidden (`"none"`), solid, or blinking (0.53s period).
///
/// When `haptic` is enabled, a `selection` haptic fires on every tick via
/// `HapticManager.shared.fire("selection")`.
///
/// Respects `UIAccessibility.isReduceMotionEnabled` -- when active the full
/// text is shown immediately with no animation.
struct TypewriterEffectView: View {

    /// The full text to reveal.
    let fullText: String

    /// Characters per second (used to derive the timer interval).
    let speed: Double

    /// Whether to reveal word-by-word instead of character-by-character.
    let wordMode: Bool

    /// Cursor style: `"none"`, `"blink"`, or `"solid"`.
    let cursor: String

    /// The character displayed as the cursor.
    let cursorChar: String

    /// Whether to fire a haptic tick on each reveal step.
    let haptic: Bool

    /// Delay in milliseconds before the effect begins.
    let delay: Double

    // MARK: - State

    /// The number of characters currently visible.
    @State private var visibleCount: Int = 0

    /// Controls cursor blink visibility.
    @State private var cursorVisible: Bool = true

    /// Active reveal timer (character/word ticks).
    @State private var revealTimer: Timer?

    /// Active cursor blink timer.
    @State private var blinkTimer: Timer?

    /// Whether the effect has completed (all text revealed).
    @State private var isComplete: Bool = false

    // MARK: - Derived

    /// The currently visible portion of the text.
    private var visibleText: String {
        if visibleCount >= fullText.count {
            return fullText
        }
        let endIndex = fullText.index(fullText.startIndex, offsetBy: visibleCount)
        return String(fullText[fullText.startIndex..<endIndex])
    }

    /// Whether the cursor should be displayed at all.
    private var showCursor: Bool {
        cursor != "none" && !isComplete
    }

    /// The cursor string to append (respects blink state).
    private var cursorString: String {
        guard showCursor else { return "" }
        if cursor == "blink" {
            return cursorVisible ? cursorChar : " "
        }
        // "solid" or any other value -- always show.
        return cursorChar
    }

    // MARK: - Body

    var body: some View {
        if isReduceMotionEnabled {
            // Show full text immediately when Reduce Motion is enabled.
            Text(fullText)
        } else {
            // Use the full text as an invisible sizing reference so the view
            // reserves its final width from the start. Without this, the view
            // hugs the partially-revealed text, causing the text to appear
            // centered/shifting when left-aligned inside a parent stack.
            Text(fullText)
                .hidden()
                .overlay(alignment: .topLeading) {
                    Text(visibleText + cursorString)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onAppear {
                    startEffect()
                }
                .onDisappear {
                    invalidateTimers()
                }
        }
    }

    // MARK: - Timer Management

    /// Starts the typewriter reveal after the configured delay.
    private func startEffect() {
        let delaySeconds = delay / 1000.0
        let interval = speed > 0 ? (1.0 / speed) : 0.025

        // Start cursor blink timer immediately (if blinking).
        if cursor == "blink" {
            let blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { _ in
                cursorVisible.toggle()
            }
            blinkTimer = blink
        }

        // Schedule the reveal timer after the configured delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
            guard !isComplete else { return }

            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                advanceReveal()
            }
            revealTimer = timer
        }
    }

    /// Advances the reveal by one step (character or word).
    private func advanceReveal() {
        guard visibleCount < fullText.count else {
            completeEffect()
            return
        }

        if wordMode {
            // Advance to the end of the next whitespace-delimited word.
            let currentIndex = fullText.index(fullText.startIndex, offsetBy: visibleCount)
            let remaining = fullText[currentIndex...]

            // Skip any leading whitespace, then find the end of the next word.
            var endOffset = visibleCount
            var foundNonSpace = false
            for (i, char) in remaining.enumerated() {
                if char.isWhitespace {
                    if foundNonSpace {
                        // End of word found.
                        endOffset = visibleCount + i
                        break
                    }
                } else {
                    foundNonSpace = true
                }
                // If we reach the end, set offset to full length.
                if visibleCount + i + 1 == fullText.count {
                    endOffset = fullText.count
                }
            }

            visibleCount = max(visibleCount + 1, endOffset)
        } else {
            visibleCount += 1
        }

        // Fire haptic tick per step.
        if haptic {
            HapticManager.shared.fire("selection")
        }

        // Check if we are done.
        if visibleCount >= fullText.count {
            completeEffect()
        }
    }

    /// Marks the effect as complete and cleans up timers.
    private func completeEffect() {
        isComplete = true
        visibleCount = fullText.count
        invalidateTimers()
    }

    /// Invalidates all active timers to prevent leaks.
    private func invalidateTimers() {
        revealTimer?.invalidate()
        revealTimer = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
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
