import SwiftUI

/// Maps TransitionConfig to native SwiftUI transitions and animations.
struct TransitionMapper {

    // MARK: - Transition Mapping

    /// Returns a SwiftUI transition for the given config.
    static func transition(for config: TransitionConfig) -> AnyTransition {
        let type = config.resolvedType

        switch type {
        case .none:
            return .identity

        case .fade:
            return .opacity

        case .slideFromRight:
            // Forward: new screen slides in from right, old screen slides out to left.
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )

        case .slideFromLeft:
            // Back: new screen slides in from left, old screen slides out to right.
            return .asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .trailing)
            )

        case .slideFromBottom:
            return .asymmetric(
                insertion: .move(edge: .bottom),
                removal: .move(edge: .bottom)
            )

        case .slideFromTop:
            return .asymmetric(
                insertion: .move(edge: .top),
                removal: .move(edge: .top)
            )

        case .push:
            // True push: incoming pushes from trailing, outgoing pushed out to leading.
            // Auto-reverse handles back direction via TransitionResolver.
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )

        case .scale:
            return .asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity),
                removal: .opacity
            )

        case .flip:
            return .asymmetric(
                insertion: .modifier(
                    active: FlipModifier(angle: -180),
                    identity: FlipModifier(angle: 0)
                ),
                removal: .modifier(
                    active: FlipModifier(angle: 180),
                    identity: FlipModifier(angle: 0)
                )
            )
        }
    }

    // MARK: - Animation Mapping

    /// Returns a SwiftUI Animation for the given config.
    static func animation(for config: TransitionConfig) -> Animation {
        let duration = config.resolvedDurationSeconds
        let easing = config.resolvedEasing

        switch easing {
        case .linear:
            return .linear(duration: duration)
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .easeInOut:
            return .easeInOut(duration: duration)
        case .spring:
            let damping = config.springDamping ?? 0.85
            let response = config.springResponse ?? 0.35
            return .spring(response: response, dampingFraction: damping)
        }
    }

    // MARK: - Reduce Motion Helpers

    static func reduceMotionTransition() -> AnyTransition {
        .opacity
    }

    static func reduceMotionAnimation() -> Animation {
        .easeInOut(duration: 0.15)
    }
}

// MARK: - Custom Flip Modifier

/// A ViewModifier for 3D flip transitions with perspective.
private struct FlipModifier: ViewModifier {
    let angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
            .opacity(abs(angle) >= 90 ? 0.0 : 1.0)
    }
}
