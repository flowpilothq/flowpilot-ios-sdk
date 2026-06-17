import Foundation

// MARK: - Theme Tokens

/// Render-time resolution of theme color token references (schema v9).
///
/// Any color-bearing prop string may be `"token:<name>"` instead of a literal
/// color. The dashboard stores the FULL palette (core + derived tones) as
/// concrete hex values in `flow.globalStyles.colors`, so resolution on-device
/// is a dictionary lookup — no color math. Unknown tokens fall back to the
/// defaults below (kept in sync with `THEME_TOKEN_FALLBACKS` in the
/// dashboard's shared types package); non-reference values pass through
/// untouched. Resolution happens in `PropertyResolver`, the same layer that
/// evaluates conditional values and `{{var}}` interpolation.
enum ThemeTokens {
    static let prefix = "token:"

    /// Defaults when the flow's palette is missing an entry.
    static let fallbacks: [String: String] = [
        "primary": "#4F46E5",
        "onPrimary": "#FFFFFF",
        "primaryLight": "#EEF2FF",
        "secondary": "#3B82F6",
        "background": "#FFFFFF",
        "surface": "#F2F2F7",
        "surfaceRaised": "#FFFFFF",
        "textPrimary": "#16181D",
        "textSecondary": "#6B7280",
        "textTertiary": "#9CA3AF",
        "border": "#E5E7EB",
        "success": "#16A34A",
        "destructive": "#EF4444",
        "onDestructive": "#FFFFFF",
        "gold": "#F59E0B",
    ]

    /// True when a value is a theme token reference ("token:primary").
    static func isRef(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    /// Resolve a possibly-token color value against the flow palette. Returns
    /// the input unchanged for non-references; unknown tokens resolve to the
    /// fallback palette and, as a last resort, the reference string itself
    /// (hex parsers treat that as unparseable and ignore it).
    static func resolve(_ value: String, colors: [String: String]?) -> String {
        guard isRef(value) else { return value }
        let token = String(value.dropFirst(prefix.count))
        return colors?[token] ?? fallbacks[token] ?? value
    }
}
