import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit

// MARK: - Particle Overlay View

/// A full-screen overlay that renders particle effects using `CAEmitterLayer`.
///
/// Placed at the top of the screen's ZStack, above all components.
/// Listens for `triggerParticleEffect` notifications (from button actions and
/// screen timeline events) and supports screen-level auto-play particle effects.
///
/// **Touches pass through** — the overlay has `allowsHitTesting(false)` so
/// particles never block user interaction with underlying components.
///
/// **Performance**: Limits simultaneous emitters to 3. Each emitter uses
/// `CAEmitterLayer` for GPU-accelerated compositing with no CPU overhead
/// for particle movement.
struct ParticleOverlayView: View {
    let screenParticleConfig: ParticleEffectConfig?

    @State private var activeEmitters: [EmitterState] = []

    var body: some View {
        ZStack {
            ForEach(activeEmitters) { emitter in
                ParticleEmitterRepresentable(config: emitter.config)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(emitter.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear {
            startScreenLevelEffect()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .triggerParticleEffect)
        ) { notification in
            handleParticleTrigger(notification.userInfo as? [String: Any] ?? [:])
        }
    }

    // MARK: - Screen-Level Effect

    private func startScreenLevelEffect() {
        guard let config = screenParticleConfig else {
            Logger.shared.debug("ParticleOverlay: No screen-level particle config")
            return
        }
        Logger.shared.debug("ParticleOverlay: Starting screen-level effect: \(config.effect.rawValue)")

        // Respect Reduce Motion
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        let delay = config.delay
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                startEmitter(config: config)
            }
        } else {
            startEmitter(config: config)
        }
    }

    // MARK: - Action-Triggered Effect

    private func handleParticleTrigger(_ userInfo: [String: Any]) {
        Logger.shared.debug("ParticleOverlay: Received triggerParticleEffect notification with keys: \(userInfo.keys.sorted())")

        // Respect Reduce Motion
        guard !UIAccessibility.isReduceMotionEnabled else {
            // Still fire haptic (accessibility-positive)
            if let haptic = userInfo["haptic"] as? String, haptic != "none" {
                HapticManager.shared.fire(haptic)
            }
            return
        }

        guard let config = ParticleEffectConfig.from(dict: userInfo) else {
            Logger.shared.warn("ParticleOverlay: Failed to parse ParticleEffectConfig from userInfo: \(userInfo)")
            return
        }
        Logger.shared.debug("ParticleOverlay: Parsed config - effect=\(config.effect.rawValue), duration=\(config.duration)s")

        // Fire haptic
        if let haptic = config.haptic, haptic != "none" {
            HapticManager.shared.fire(haptic)
        }

        startEmitter(config: config)
    }

    // MARK: - Emitter Management

    private func startEmitter(config: ParticleEffectConfig) {
        Logger.shared.debug("ParticleOverlay: startEmitter called - effect=\(config.effect.rawValue), activeEmitters=\(activeEmitters.count)")

        // Performance: limit to 3 simultaneous emitters
        if activeEmitters.count >= 3 {
            // Remove oldest
            activeEmitters.removeFirst()
        }

        let emitter = EmitterState(id: UUID(), config: config)
        activeEmitters.append(emitter)
        Logger.shared.debug("ParticleOverlay: Emitter added, total=\(activeEmitters.count)")

        // Schedule removal after duration + fade-out buffer
        if !config.loop {
            let totalDuration = config.duration + 0.5 // extra time for particles in flight
            DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) {
                activeEmitters.removeAll { $0.id == emitter.id }
            }
        }
    }
}

// MARK: - Emitter State

/// Identifies an active particle emitter instance.
private struct EmitterState: Identifiable {
    let id: UUID
    let config: ParticleEffectConfig
}

// MARK: - UIViewRepresentable Wrapper

/// Bridges a `CAEmitterLayer` into SwiftUI via a `UIView` host.
private struct ParticleEmitterRepresentable: UIViewRepresentable {
    let config: ParticleEffectConfig

    func makeUIView(context: Context) -> ParticleHostView {
        let view = ParticleHostView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ParticleHostView, context: Context) {
        uiView.startEmitting(config: config)
    }
}

// MARK: - Particle Host View

/// UIView that owns and manages a `CAEmitterLayer`.
///
/// Handles layout updates (frame changes) and cleanup on dealloc.
/// Stops emission after the configured duration while letting
/// already-emitted particles complete their flight naturally.
private class ParticleHostView: UIView {
    private var emitterLayer: CAEmitterLayer?
    private var stopWorkItem: DispatchWorkItem?

    func startEmitting(config: ParticleEffectConfig) {
        Logger.shared.debug("ParticleHostView: startEmitting called, bounds=\(bounds)")

        // Remove any existing emitter
        stopWorkItem?.cancel()
        emitterLayer?.removeFromSuperlayer()

        // Wait for layout if bounds are empty
        guard bounds.width > 0 && bounds.height > 0 else {
            Logger.shared.debug("ParticleHostView: Bounds are zero, deferring to layoutSubviews")
            // Store config and retry after layout
            pendingConfig = config
            return
        }
        Logger.shared.debug("ParticleHostView: Creating emitter layer for bounds=\(bounds)")

        let emitter = ParticleEmitterFactory.makeEmitter(
            config: config,
            bounds: bounds
        )
        layer.addSublayer(emitter)
        emitterLayer = emitter

        // Stop emission after duration (particles already in flight continue)
        if !config.loop {
            let workItem = DispatchWorkItem { [weak self] in
                self?.emitterLayer?.birthRate = 0
            }
            stopWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + config.duration, execute: workItem)
        }
    }

    private var pendingConfig: ParticleEffectConfig?

    override func layoutSubviews() {
        super.layoutSubviews()
        emitterLayer?.frame = bounds

        // If we had a pending config waiting for layout, apply it now
        if let config = pendingConfig, bounds.width > 0, bounds.height > 0 {
            pendingConfig = nil
            startEmitting(config: config)
        }
    }

    deinit {
        stopWorkItem?.cancel()
        emitterLayer?.removeFromSuperlayer()
    }
}

#endif
