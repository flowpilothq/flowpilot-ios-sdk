import Foundation

// MARK: - Background Resolution

enum BackgroundSource: Equatable {
    case screen
    case flow
    case legacy
    case `default`
}

struct ResolvedBackground: Equatable {
    let layers: [BackgroundLayer]
    let source: BackgroundSource
}

/// Resolves the effective background layers for a screen,
/// applying inheritance from flow-level if needed.
///
/// Priority chain (matches web editor exactly):
/// 1. Screen has explicit background AND backgroundInherit == false → screen layers
/// 2. backgroundInherit != false AND flow has background → flow layers (inherit)
/// 3. Screen has background (no flow bg) → screen layers
/// 4. Legacy gradient field → migrate to single gradient layer
/// 5. Legacy backgroundColor field → migrate to single solid layer
/// 6. Default → empty layers
func resolveScreenBackground(
    screen: ScreenNode,
    flow: FlowDefinition
) -> ResolvedBackground {

    // 1. Screen has explicit background (not inheriting)
    if screen.props?.backgroundInherit == false,
       let bg = screen.props?.background,
       !bg.layers.isEmpty {
        return ResolvedBackground(layers: bg.layers, source: .screen)
    }

    // 2. Inherit from flow-level
    if screen.props?.backgroundInherit != false,
       let flowBg = flow.background,
       !flowBg.layers.isEmpty {
        return ResolvedBackground(layers: flowBg.layers, source: .flow)
    }

    // 3. Screen has explicit background but inherit wasn't explicitly false
    //    (screen bg exists, no flow bg exists — use screen bg)
    if let bg = screen.props?.background,
       !bg.layers.isEmpty {
        return ResolvedBackground(layers: bg.layers, source: .screen)
    }

    // 4. Legacy gradient fallback
    if let gradient = screen.props?.gradient,
       gradient.colors.count >= 2 {
        let stops = gradient.colors.enumerated().map { index, color in
            GradientStop(
                color: color,
                position: gradient.colors.count > 1
                    ? Double(index) / Double(gradient.colors.count - 1) * 100
                    : 0
            )
        }
        let layer = BackgroundLayer(
            id: "migrated_gradient",
            type: .gradient,
            enabled: true,
            opacity: 100,
            color: nil,
            gradient: GradientDefinition(
                type: .linear,
                colors: stops,
                angle: gradient.angle ?? 180,
                centerX: nil,
                centerY: nil
            ),
            image: nil,
            motion: nil
        )
        return ResolvedBackground(layers: [layer], source: .legacy)
    }

    // 5. Legacy solid color fallback
    if let bgColor = screen.props?.backgroundColor {
        let layer = BackgroundLayer(
            id: "migrated_solid",
            type: .solid,
            enabled: true,
            opacity: 100,
            color: bgColor,
            gradient: nil,
            image: nil,
            motion: nil
        )
        return ResolvedBackground(layers: [layer], source: .legacy)
    }

    // 6. Default — empty (caller should use platform default)
    return ResolvedBackground(layers: [], source: .default)
}
