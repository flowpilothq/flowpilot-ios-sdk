import SwiftUI

// MARK: - Unit System (shared Imperial / Metric CONTRACT)

/// The built-in Imperial/Metric conversion CONTRACT shared by the `picker` and
/// `ruler` primitives. Both the wheel picker's per-column unit toggle and the
/// ruler's single-track unit toggle convert values through this ONE table and
/// emit the same canonical kg / cm output. The dashboard's `unit-system.ts` is
/// the source of truth — keep the `perBase` numbers, the switch geometry, and
/// the helpers in lockstep across the three layers (dashboard / iOS / Expo).
///
/// The picker keeps its own column-specific distribution math (the ft+in split);
/// this module is dimension-agnostic and only provides the table + scalar
/// conversions + the switch geometry both primitives share.
enum UnitSystem {
    struct UnitInfo {
        /// "mass" or "length".
        let dimension: String
        /// How many of this unit equal one BASE unit of its dimension
        /// (mass base = kg, length base = cm). So `value = base * perBase` and
        /// `base = value / perBase`.
        let perBase: Double
    }

    /// Built-in unit conversion table. EXACT numbers from the dashboard
    /// `UNIT_TABLE` — units absent from the table get no conversion.
    static let table: [String: UnitInfo] = [
        // mass — base kg
        "kg": UnitInfo(dimension: "mass", perBase: 1),
        "g":  UnitInfo(dimension: "mass", perBase: 1000),
        "lb": UnitInfo(dimension: "mass", perBase: 2.2046226218),
        "st": UnitInfo(dimension: "mass", perBase: 0.1574730444),
        // length — base cm
        "cm": UnitInfo(dimension: "length", perBase: 1),
        "m":  UnitInfo(dimension: "length", perBase: 0.01),
        "mm": UnitInfo(dimension: "length", perBase: 10),
        "in": UnitInfo(dimension: "length", perBase: 0.3937007874),
        "ft": UnitInfo(dimension: "length", perBase: 0.0328083990),
    ]

    /// Lookup for a unit key (trimmed + lowercased so authored "Kg"/"LB" match).
    static func info(_ unit: String?) -> UnitInfo? {
        guard let unit else { return nil }
        return table[unit.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Dimension of a unit, or nil if not in the table (→ no conversion).
    static func dimension(of unit: String?) -> String? {
        info(unit)?.dimension
    }

    /// Convert a value in `unit` to its dimension's base (kg / cm). Identity if unknown.
    static func toBase(_ value: Double, unit: String?) -> Double {
        guard let i = info(unit) else { return value }
        return value / i.perBase
    }

    /// Convert a base value (kg / cm) into `unit`. Identity if unknown.
    static func fromBase(_ base: Double, unit: String?) -> Double {
        guard let i = info(unit) else { return base }
        return base * i.perBase
    }

    /// Convert a scalar from one unit to another. Returns the input unchanged when
    /// either unit is unknown or the two units span different dimensions (a pure
    /// system swap with no physical conversion). This single-scalar convert is all
    /// a `ruler` needs — there is no multi-column distribution like the wheel
    /// picker's ft+in split.
    static func convertScalar(_ value: Double, from fromUnit: String?, to toUnit: String?) -> Double {
        guard let from = info(fromUnit), let to = info(toUnit), from.dimension == to.dimension else {
            return value
        }
        return (value / from.perBase) * to.perBase
    }
}

// MARK: - Switch Geometry

/// Geometry of the "switch"-style unit toggle (label ─◯─ label), mirrored EXACTLY
/// from the editor's `UNIT_SWITCH` (unit-system.ts) so the knob position + track
/// size match across all three layers. The first option is the OFF (knob-left)
/// position, the second is ON (knob-right); the active side's label is
/// emphasised. The track stays a neutral gray in both states (matching the iOS
/// reference) so it is theme- and background-independent.
enum UnitSwitchMetrics {
    static let trackWidth: CGFloat = 51
    static let trackHeight: CGFloat = 31
    static let knobSize: CGFloat = 27
    static let knobPadding: CGFloat = 2
    static let labelFontSize: CGFloat = 18
    static let labelGap: CGFloat = 12
    // Neutral gray track (both states) over any background, matching the editor.
    static let trackColor = Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(0.32)
    static let knobColor = Color.white
}

/// Whether a unit toggle should render as the side-by-side binary switch: opted
/// in via `toggleStyle == "switch"` AND exactly two options. Any other count
/// degrades to the segmented control. Mirrors `isSwitchToggle` on the dashboard.
func isSwitchToggle(style: String?, optionCount: Int) -> Bool {
    style == "switch" && optionCount == 2
}
