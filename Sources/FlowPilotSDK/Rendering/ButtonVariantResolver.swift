import SwiftUI

// MARK: - Flow Global Styles Environment Key

/// Environment key that carries the active flow's global style tokens down to
/// renderers. Set once at the FlowPresenter level next to `animationSpeedMultiplier`;
/// consumed by components that need theme-token resolution (currently `ButtonView`
/// for variant defaults — see ComponentOverhaulPlan §2.1 / §8.4).
struct FlowGlobalStylesKey: EnvironmentKey {
    static let defaultValue: FlowGlobalStyles? = nil
}

extension EnvironmentValues {
    var flowGlobalStyles: FlowGlobalStyles? {
        get { self[FlowGlobalStylesKey.self] }
        set { self[FlowGlobalStylesKey.self] = newValue }
    }
}

// MARK: - Button Variant Resolution

enum ButtonVariant: String, Sendable {
    case primary
    case secondary
    case ghost
    case destructive

    static func from(_ raw: String?) -> ButtonVariant {
        switch raw {
        case "secondary": return .secondary
        case "ghost": return .ghost
        case "destructive": return .destructive
        default: return .primary
        }
    }
}

struct ResolvedButtonVariant {
    let backgroundHex: String
    let textHex: String
    let borderHex: String?
    let borderWidth: CGFloat
}

private enum ButtonVariantFallback {
    static let primary = "#4F46E5"
    static let onPrimary = "#FFFFFF"
    static let text = "#000000"
    static let border = "#E5E7EB"
    static let destructive = "#EF4444"
    static let onDestructive = "#FFFFFF"
}

/// Variant-derived default props to merge into a button's props before the
/// universal style pass (overhaul §2.2). Only background/border are injected so
/// they paint on the padded, clipped frame; the button's text color is resolved
/// inside `ButtonView`. Transparent variants inject no background so the frame
/// stays clear. Per-prop overrides on the node win via `ComponentProps.merging`.
func buttonVariantDefaultProps(
    _ variant: ButtonVariant,
    globalStyles: FlowGlobalStyles?
) -> [String: AnyCodable] {
    let resolved = resolveButtonVariant(variant, globalStyles: globalStyles)
    var defaults: [String: AnyCodable] = [:]
    if resolved.backgroundHex != "transparent" {
        defaults["backgroundColor"] = AnyCodable(resolved.backgroundHex)
    }
    if let borderHex = resolved.borderHex, resolved.borderWidth > 0 {
        defaults["borderColor"] = AnyCodable(borderHex)
        defaults["borderWidth"] = AnyCodable(Double(resolved.borderWidth))
    }
    return defaults
}

func resolveButtonVariant(
    _ variant: ButtonVariant,
    globalStyles: FlowGlobalStyles?
) -> ResolvedButtonVariant {
    let colors = globalStyles?.colors ?? [:]
    let primary = colors["primary"] ?? ButtonVariantFallback.primary
    let onPrimary = colors["onPrimary"] ?? ButtonVariantFallback.onPrimary
    // textPrimary is the canonical v9 token; `text` is the legacy alias.
    let text = colors["textPrimary"] ?? colors["text"] ?? ButtonVariantFallback.text
    let border = colors["border"] ?? ButtonVariantFallback.border
    let destructive = colors["destructive"] ?? ButtonVariantFallback.destructive
    let onDestructive = colors["onDestructive"] ?? ButtonVariantFallback.onDestructive

    switch variant {
    case .primary:
        return ResolvedButtonVariant(
            backgroundHex: primary,
            textHex: onPrimary,
            borderHex: nil,
            borderWidth: 0
        )
    case .secondary:
        return ResolvedButtonVariant(
            backgroundHex: "transparent",
            textHex: text,
            borderHex: border,
            borderWidth: 1
        )
    case .ghost:
        return ResolvedButtonVariant(
            backgroundHex: "transparent",
            textHex: primary,
            borderHex: nil,
            borderWidth: 0
        )
    case .destructive:
        return ResolvedButtonVariant(
            backgroundHex: destructive,
            textHex: onDestructive,
            borderHex: nil,
            borderWidth: 0
        )
    }
}
