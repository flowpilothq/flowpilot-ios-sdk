# Changelog

All notable changes to the FlowPilot iOS SDK are documented here. This project
adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0]

Initial public release.

- Server-driven flow rendering (JSON to native SwiftUI), with UIKit and SwiftUI presentation entry points.
- Fail-safe delivery: fresh cache, live resolve with a hard timeout, stale-cache fallback, bundled default flows, and host fallback.
- Variables, conditional rendering, and A/B testing with automatic variant assignment.
- Custom component registration.
- Automatic analytics with batching and offline support; conversion tracking.
- Prefetching (manual and at-launch) with configurable media-warming strategy.
- Apple privacy manifest (`PrivacyInfo.xcprivacy`) included.
