# Changelog

All notable changes to the FlowPilot iOS SDK are documented here. This project
adheres to [Semantic Versioning](https://semver.org/).

## [1.3.0]

- In-flow A/B attribution: every analytics event now carries an `ab_assignments` map (abTest node id → chosen variant id) once any in-flow abTest node has bucketed, enabling per-variant funnels distinct from the server-side `experiment_id`/`variant_id` columns. The map is persisted with saved progress and reseeded on a resumed session.
- Fix: an in-flow abTest exposure is now emitted only on first bucketing, so re-traversing the node no longer inflates the per-variant denominator.

## [1.2.0]

- Picker (wheel) component, with an optional Imperial/Metric unit-system toggle and a shared centered header across grouped picker columns.
- Ruler component (horizontal scrubbing scale) that shares the same unit-system toggle.
- Modern slider styling: configurable track thickness, a leading-to-trailing gradient fill, a pill thumb style with adjustable size, and a top value readout with its own size and color.
- Fix: in an over-allocated horizontal row, two `width: 100%` siblings now shrink to share the row (CSS flex-shrink) instead of each filling it and overflowing; a lone 100%-width child still expands normally.

## [1.1.1]

- Fix: percentage widths now resolve correctly when stacks are nested (a lone 33% child no longer renders full-width, and 50/50 rows are exact rather than incidental).
- Fix: an overlay whose root width is `auto` hugs its content so positioned anchors (e.g. top-trailing) work as designed.
- Fix: over-wide rows of rigid children shrink to fit instead of overflowing and dragging full-width siblings off the content box (matching the editor's default flex-shrink).
- Fix: the progress bar holds at the last counted step on screens excluded from progress, instead of collapsing to zero.
- Fix: press feedback no longer blocks scrolling. Pressing a card inside a list registers the tap and still lets the list scroll.

## [1.1.0]

- Identity API: `FlowPilot.identify(_:)` ties events to a stable, app-provided user id (Keychain-persisted across launches), and `FlowPilot.reset()` clears it on logout.
- Resume flows from saved user progress, so returning users continue where they left off.
- Comparison chart: gridlines, start dots, and a hollow dot style.
- Linear progress bar driven by an `autoProgress` timeline.
- Button icon/label children, full-width zones, and component gradients.
- Analytics events carry an `is_debug` flag so DEBUG-build traffic can be excluded from production counts.
- Fixes: non-100% percentage width/height for images; scroll content pinned to the viewport width to stop over-wide child overflow.

## [1.0.0]

Initial public release.

- Server-driven flow rendering (JSON to native SwiftUI), with UIKit and SwiftUI presentation entry points.
- Fail-safe delivery: fresh cache, live resolve with a hard timeout, stale-cache fallback, bundled default flows, and host fallback.
- Variables, conditional rendering, and A/B testing with automatic variant assignment.
- Custom component registration.
- Automatic analytics with batching and offline support; conversion tracking.
- Prefetching (manual and at-launch) with configurable media-warming strategy.
- Apple privacy manifest (`PrivacyInfo.xcprivacy`) included.
