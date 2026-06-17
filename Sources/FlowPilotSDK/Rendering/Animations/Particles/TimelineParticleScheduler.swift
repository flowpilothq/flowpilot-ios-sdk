import SwiftUI

#if canImport(UIKit)

// MARK: - Timeline Particle Scheduler

/// A SwiftUI view modifier that fires scheduled particle events from the
/// screen-level timeline when the screen appears.
///
/// Particle timeline events are resolved by `ScreenTimelineResolver.computeParticleEvents()`
/// into absolute delays. This modifier schedules `DispatchQueue.main.asyncAfter` calls
/// to post `triggerParticleEffect` notifications at the correct times.
struct TimelineParticleScheduler: ViewModifier {
    let events: [ScreenTimelineResolver.ScheduledParticleEvent]

    @State private var scheduledWorkItems: [DispatchWorkItem] = []

    func body(content: Content) -> some View {
        content
            .onAppear {
                scheduleParticleEvents()
            }
            .onDisappear {
                cancelScheduledEvents()
            }
    }

    private func scheduleParticleEvents() {
        cancelScheduledEvents()

        guard !UIAccessibility.isReduceMotionEnabled else { return }

        for event in events {
            let workItem = DispatchWorkItem {
                NotificationCenter.default.post(
                    name: .triggerParticleEffect,
                    object: nil,
                    userInfo: event.config
                )
            }
            scheduledWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + event.delay, execute: workItem)
        }
    }

    private func cancelScheduledEvents() {
        for item in scheduledWorkItems {
            item.cancel()
        }
        scheduledWorkItems.removeAll()
    }
}

#endif
