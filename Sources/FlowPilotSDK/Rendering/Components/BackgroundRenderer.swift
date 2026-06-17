import SwiftUI

// MARK: - Background Renderer

/// Renders a stack of background layers (solid, gradient, image, motion)
/// behind the screen content. Each layer is absolutely positioned and
/// composited in order (index 0 = bottommost).
struct BackgroundRenderer: View {
    let layers: [BackgroundLayer]
    let reducedMotion: Bool

    var body: some View {
        ZStack {
            ForEach(layers) { layer in
                if layer.enabled {
                    BackgroundLayerView(layer: layer, reducedMotion: reducedMotion)
                        .opacity(Double(layer.opacity ?? 100) / 100.0)
                }
            }
        }
    }
}

struct BackgroundLayerView: View {
    let layer: BackgroundLayer
    let reducedMotion: Bool

    var body: some View {
        switch layer.type {
        case .solid:
            SolidBackgroundLayer(color: layer.color ?? "#FFFFFF")

        case .gradient:
            if let gradient = layer.gradient {
                GradientBackgroundLayer(gradient: gradient)
            }

        case .image:
            if let image = layer.image {
                ImageBackgroundLayer(image: image)
            }

        case .motion:
            if let motion = layer.motion {
                if reducedMotion {
                    MotionStaticFallback(motion: motion)
                } else {
                    MotionBackgroundLayer(motion: motion)
                }
            }
        }
    }
}

// MARK: - Solid Background Layer

struct SolidBackgroundLayer: View {
    let color: String

    var body: some View {
        (Color(hex: color) ?? Color.white)
            .ignoresSafeArea()
    }
}
