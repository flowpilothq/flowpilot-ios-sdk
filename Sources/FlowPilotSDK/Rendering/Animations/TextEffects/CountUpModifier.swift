import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Count-Up Effect View

/// Animates numeric portions of a text string from 0 to their target values.
///
/// Matches the editor's `countUp` text effect. Given a target string like
/// `"$2,847"`, this view extracts the numeric segments, animates each
/// from 0 to the target value using an ease-out curve, and preserves all
/// non-numeric text (currency symbols, units, commas, decimals) in place.
///
/// Duration calculation matches the editor:
///   `duration = min(maxNumericValue / speed, 3.0)` seconds.
/// At the default speed of 40, a value of 2847 yields a 3.0s animation
/// (capped at the 3s maximum).
///
/// Respects `UIAccessibility.isReduceMotionEnabled` -- when active, the final
/// text is shown immediately with no animation.
struct CountUpEffectView: View {

    /// The target text containing numeric values (e.g., "$2,847 steps").
    let targetText: String

    /// Units per second, used to derive animation duration (legacy fallback).
    let speed: Double

    /// Delay in milliseconds before the animation starts.
    let delay: Double

    /// Explicit total animation duration in milliseconds. If set, takes priority over speed-based derivation.
    let duration: Double?

    // MARK: - State

    /// Animation progress from 0.0 to 1.0.
    @State private var progress: Double = 0.0

    /// Timer driving the count-up animation.
    @State private var animationTimer: Timer?

    /// Whether the animation has started (prevents re-entry on re-appear).
    @State private var hasStarted: Bool = false

    // MARK: - Parsed Segments

    /// Represents a segment of the target text -- either a number or plain text.
    private enum Segment {
        case number(value: Double, formatted: String, hasDecimal: Bool, decimalPlaces: Int, hasCommas: Bool)
        case text(String)
    }

    /// Parses the target text into segments of numbers and non-numbers.
    private var segments: [Segment] {
        var result: [Segment] = []
        var remaining = targetText[targetText.startIndex...]

        while !remaining.isEmpty {
            if let match = findNumberPrefix(in: remaining) {
                result.append(match.segment)
                remaining = remaining[match.endIndex...]
            } else {
                result.append(.text(String(remaining.first!)))
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }
        }

        return result
    }

    /// Attempts to match a numeric pattern at the start of the given substring.
    /// Handles patterns like "2,847", "3.14", "1,234.56", or plain "42".
    private func findNumberPrefix(in str: Substring) -> (segment: Segment, endIndex: String.Index)? {
        guard let first = str.first, first.isNumber else { return nil }

        var numberStr = ""
        var rawDigits = ""
        var hasDecimal = false
        var decimalPlaces = 0
        var hasCommas = false
        var index = str.startIndex

        while index < str.endIndex {
            let char = str[index]

            if char.isNumber {
                numberStr.append(char)
                rawDigits.append(char)
                if hasDecimal { decimalPlaces += 1 }
                index = str.index(after: index)
            } else if char == "," {
                let nextIndex = str.index(after: index)
                if nextIndex < str.endIndex, str[nextIndex].isNumber, !numberStr.isEmpty {
                    hasCommas = true
                    numberStr.append(char)
                    index = nextIndex
                } else {
                    break
                }
            } else if char == "." && !hasDecimal {
                let nextIndex = str.index(after: index)
                if nextIndex < str.endIndex, str[nextIndex].isNumber {
                    hasDecimal = true
                    numberStr.append(char)
                    index = nextIndex
                } else {
                    break
                }
            } else {
                break
            }
        }

        guard let value = Double(rawDigits.isEmpty ? numberStr : rawDigits) else { return nil }

        let segment = Segment.number(
            value: value,
            formatted: numberStr,
            hasDecimal: hasDecimal,
            decimalPlaces: decimalPlaces,
            hasCommas: hasCommas
        )
        return (segment, index)
    }

    /// Builds the display string at the current animation progress.
    private var displayText: String {
        segments.map { segment in
            switch segment {
            case .number(let target, _, let hasDecimal, let decimalPlaces, let hasCommas):
                let current = target * progress
                return formatNumber(current, hasDecimal: hasDecimal, decimalPlaces: decimalPlaces, hasCommas: hasCommas)

            case .text(let str):
                return str
            }
        }.joined()
    }

    /// Formats a number to match the original formatting (commas, decimal places).
    private func formatNumber(_ value: Double, hasDecimal: Bool, decimalPlaces: Int, hasCommas: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = hasCommas ? .decimal : .none

        if hasDecimal {
            formatter.minimumFractionDigits = decimalPlaces
            formatter.maximumFractionDigits = decimalPlaces
        } else {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        }

        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    /// The largest numeric value in the target text, used to compute duration.
    private var maxNumericValue: Double {
        var maxVal: Double = 0
        for segment in segments {
            if case .number(let value, _, _, _, _) = segment {
                maxVal = max(maxVal, value)
            }
        }
        return maxVal
    }

    /// Computed animation duration in seconds.
    /// Uses explicit `duration` (ms) if set, otherwise derives from speed.
    private var animationDuration: Double {
        // Use explicit duration if set (convert ms to seconds)
        if let duration = duration {
            return max(duration / 1000.0, 0.5)
        }
        // Legacy: derive from speed
        let effectiveSpeed = max(speed, 1)
        let baseDuration = maxNumericValue / effectiveSpeed
        return min(max(baseDuration, 0.5), 3.0)
    }

    // MARK: - Body

    var body: some View {
        if isReduceMotionEnabled {
            Text(targetText)
        } else {
            Text(displayText)
                .monospacedDigit()
                .onAppear {
                    startAnimation()
                }
                .onDisappear {
                    invalidateTimer()
                }
        }
    }

    // MARK: - Animation

    /// Starts the count-up animation after the configured delay.
    private func startAnimation() {
        guard !hasStarted else { return }
        hasStarted = true

        // If there are no numbers in the text, skip animation entirely.
        guard maxNumericValue > 0 else {
            progress = 1.0
            return
        }

        let delaySeconds = delay / 1000.0
        let duration = animationDuration
        let frameRate: Double = 60.0
        let totalFrames = max(1, Int(duration * frameRate))
        var currentFrame = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
            let interval = 1.0 / frameRate
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                currentFrame += 1
                let linearProgress = Double(currentFrame) / Double(totalFrames)

                // Ease-out cubic curve: 1 - (1 - t)^3
                let easedProgress = 1.0 - pow(1.0 - min(linearProgress, 1.0), 3)
                progress = min(easedProgress, 1.0)

                if currentFrame >= totalFrames {
                    progress = 1.0
                    invalidateTimer()
                }
            }
            animationTimer = timer
        }
    }

    /// Invalidates the animation timer.
    private func invalidateTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
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
