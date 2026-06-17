import SwiftUI
import Combine

// MARK: - Screen Lifecycle Publisher

/// Observable object that signals screen lifecycle events to child components.
///
/// Created per-screen and injected into the SwiftUI environment as an
/// `@EnvironmentObject`. Components with exit animations subscribe to
/// `exitPublisher` to know when to begin their exit animation sequence.
///
/// **Usage from FlowPresenter**:
/// ```swift
/// let lifecycle = ScreenLifecyclePublisher()
/// screenContentView(for: screen)
///     .environmentObject(lifecycle)
///
/// // Before navigating away:
/// lifecycle.triggerExit()
/// ```
///
/// **Usage from AnimationModifier**:
/// The modifier optionally reads this from the environment and subscribes
/// to the exit publisher to animate to the exit state.
final class ScreenLifecyclePublisher: ObservableObject {
    /// Publisher that fires when the screen is about to exit.
    let exitPublisher = PassthroughSubject<Void, Never>()

    /// Signals all subscribed components that the screen is exiting.
    ///
    /// Components with `exitAnimation.trigger == "screenExit"` will begin
    /// their exit animation sequence when this fires.
    func triggerExit() {
        exitPublisher.send()
    }
}
