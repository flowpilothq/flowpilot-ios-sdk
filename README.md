# FlowPilot iOS SDK

A powerful SDK for rendering dynamic in-app flows, onboarding experiences, and A/B tested UI without app store releases.

> **Integrating FlowPilot can never take down your app.** The SDK is built to fail safe: it never crashes the host app and never shows a broken screen. See [Reliability & Fail-Safe Behavior](#reliability--fail-safe-behavior).

## Features

- **Dynamic Flows**: Render server-driven UI flows without app updates
- **Fail-Safe by Design**: Cache-first rendering, hard resolve timeout, graceful degradation, and a host fallback. Integrating FlowPilot can never take down your app.
- **A/B Testing**: Built-in experiment support with automatic variant assignment
- **Variables System**: Reactive state management with conditional rendering
- **Custom Components**: Register your own components and screens
- **Analytics**: Automatic event tracking with batching and offline support
- **Caching**: Multi-layer caching for optimal performance
- **SwiftUI & UIKit**: Native support for both frameworks

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15.0+

## Installation

### Swift Package Manager (Xcode)

In Xcode: **File → Add Package Dependencies…**, paste the package URL, and choose the **Up to Next Major Version** rule from `1.0.0`:

```
https://github.com/flowpilothq/flowpilot-ios-sdk.git
```

### Swift Package Manager (Package.swift)

```swift
dependencies: [
    .package(url: "https://github.com/flowpilothq/flowpilot-ios-sdk.git", from: "1.0.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "FlowPilotSDK", package: "flowpilot-ios-sdk")
        ]
    )
]
```

> The SDK pulls in one transitive dependency, [airbnb/lottie-ios](https://github.com/airbnb/lottie-ios) (4.x), for animated content. SPM resolves it automatically.

## Quick Start

### 1. Configure the SDK

Configure FlowPilot at app launch (typically in `AppDelegate` or `@main` App):

```swift
import FlowPilotSDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        FlowPilot.configure(FlowPilotConfiguration(
            apiKey: "fp_live_your_api_key",
            appId: "your-app-id",
            environment: .production,
            context: [
                "user.id": "user_123",
                "user.name": "John",
                "user.is_premium": true
            ]
        ))

        return true
    }
}
```

### 2. Present a Flow (UIKit)

```swift
class OnboardingViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        Task {
            guard let flowPilot = FlowPilot.shared else { return }

            do {
                let result = try await flowPilot.presentPlacement(
                    "onboarding",
                    from: self
                )

                switch result.outcome {
                case .completed:
                    print("User completed the flow!")
                    navigateToHome()
                case .dismissed:
                    print("User dismissed the flow")
                case .error:
                    print("Flow error: \(result.error?.message ?? "Unknown")")
                }
            } catch {
                print("Failed to present flow: \(error)")
            }
        }
    }
}
```

### 3. Present a Flow (SwiftUI)

```swift
import SwiftUI
import FlowPilotSDK

struct ContentView: View {
    @State private var flowSession: FlowSession?

    var body: some View {
        VStack {
            Button("Start Onboarding") {
                Task {
                    flowSession = try? await FlowPilot.shared?.createSession(
                        placementKey: "onboarding"
                    )
                }
            }
        }
        .flowPresenter(session: $flowSession) { result in
            print("Flow completed with outcome: \(result.outcome)")
        }
    }
}
```

## Configuration Options

```swift
FlowPilotConfiguration(
    // Required
    apiKey: "fp_live_xxx",           // Your FlowPilot API key
    appId: "your-app-id",            // Your app ID from the dashboard

    // Environment
    environment: .production,         // .development, .staging, .production

    // SDK Context (for variable resolution)
    context: [
        "user.id": "user_123",
        "user.name": "John",
        "user.email": "john@example.com",
        "user.is_premium": true
    ],

    // Caching
    cachingEnabled: true,             // Enable flow caching
    cacheDirectory: nil,              // Custom cache directory

    // Resilience
    resolveTimeout: 4.0,              // Hard deadline (seconds) for resolving a placement
    bundledFlows: [                   // Build-time offline defaults: placement -> bundle JSON resource
        "onboarding": "OnboardingDefault"   // loads OnboardingDefault.json from the app bundle
    ],

    // Debugging
    debugMode: false,                 // Enable debug overlay
    logLevel: .error                  // .none, .error, .warn, .info, .debug, .verbose
)
```

## Updating Context

Update the SDK context at runtime (e.g., after user login):

```swift
FlowPilot.shared?.updateContext([
    "user.id": "user_456",
    "user.name": "Jane",
    "user.is_premium": true
])
```

## Prefetching

Warm placements ahead of time so a later `presentPlacement` is instant (served
from cache, no network round-trip). Prefetch resolves each placement, caches the
flow JSON and custom fonts, and (optionally) warms first-screen images.

### Manual prefetch

```swift
let outcomes = await FlowPilot.shared?.prefetch(["onboarding", "paywall", "feature_tour"])
```

`prefetch` never throws. It returns a `[String: PrefetchOutcome]` so you can see,
per placement, exactly what is warm, without a second round-trip:

```swift
for (key, outcome) in outcomes ?? [:] {
    switch outcome.state {
    case .warmed(let fromCache):
        // A presentable flow is cached. `fromCache` is true when it came from a
        // local cached copy, false when freshly resolved or bundled.
        print("\(key): ready (fromCache: \(fromCache), media: \(outcome.mediaWarmed))")
    case .noFlow:
        // Resolve succeeded but the backend has nothing to show for this placement.
        print("\(key): no flow")
    case .failed(let error):
        // Resolve failed and no fallback was available; nothing warmed.
        print("\(key): failed (\(error))")
    }
}
```

The result is `@discardableResult`, so existing `await prefetch([...])` call sites
keep working unchanged.

By default a bare `prefetch([...])` warms JSON + fonts only. To also warm images,
opt in with `warmMedia: true` (bounded by `prefetchMediaStrategy`, see below):

```swift
await FlowPilot.shared?.prefetch(["onboarding"], warmMedia: true)
```

### Prefetch at launch

Declare placements to warm automatically right after `configure(...)`. Warming
runs in the background at utility priority and never blocks startup:

```swift
FlowPilot.configure(FlowPilotConfiguration(
    apiKey: "fp_...",
    appId: "...",
    prefetchOnLaunch: ["onboarding", "paywall"],
    prefetchMediaStrategy: .firstScreen   // .none | .firstScreen (default) | .allScreens
))
```

`prefetchMediaStrategy` controls how aggressively launch prefetch warms images:

| Strategy | Warms |
|----------|-------|
| `.none` | flow JSON + fonts only |
| `.firstScreen` (default) | + first-screen and persistent-zone images |
| `.allScreens` | + every screen's images |

> **Caching must be on, and the TTL must be non-zero.** Launch prefetch is a
> no-op when `cachingEnabled == false` (nothing would be retained). A warmed flow
> also only lives as long as its freshness TTL (driven by the resolve response's
> `cacheTtlSeconds`); the `.development` and `.custom` environments disable HTTP
> caching, so against a backend that returns a `0` TTL a warmed entry expires
> immediately. Use `.staging` / `.production` (or a backend that returns a
> non-zero TTL) to see the benefit.

### Checking readiness

`isPlacementReady` resolves through the same cache-populating path, so the
resolve it performs is **not** wasted: a presentable flow is left warm and the
following `presentPlacement` hits the cache with no second round-trip.

```swift
if await FlowPilot.shared?.isPlacementReady("onboarding") == true {
    FlowPilot.shared?.presentPlacement("onboarding")   // served from cache
}
```

## Analytics

### Automatic Events

The SDK automatically tracks:
- `flow_start` - When a flow begins
- `flow_complete` - When a user completes a flow
- `flow_exit` - When a user dismisses a flow
- `screen_view` - When a screen is displayed
- `screen_exit` - When a user leaves a screen (carries `time_on_screen_ms`)
- `element_interaction` - When a user interacts with a component (tap / toggle / change)
- `experiment_exposure` - When a user is assigned to an A/B test variant
- `conversion` - When you call `trackConversion(...)` (see below)

### Custom Analytics Callback

```swift
FlowPilot.shared?.setAnalyticsCallback { event in
    // Forward to your analytics provider
    Analytics.track(event.eventName, properties: [
        "flow_id": event.flowId,
        "screen_id": event.screenId ?? "",
        "experiment_id": event.experimentId ?? ""
    ])
}
```

### Tracking Conversions

Call `trackConversion` after a purchase completes (e.g. in your `SKPaymentTransactionObserver` callback or your IAP library's success handler). The event is attributed to the most-recently-presented flow, so revenue rolls up against the paywall / onboarding flow that triggered the purchase.

```swift
// Minimal - just amount + currency
FlowPilot.shared?.trackConversion(amount: 9.99, currency: "USD")

// With product ID and custom metadata
FlowPilot.shared?.trackConversion(
    amount: 9.99,
    currency: "USD",
    productId: "premium_yearly",
    metadata: ["trial": true, "source": "paywall_a"]
)
```

If you already hold a `FlowSession` (e.g. from `createSession`), you can call `session.trackConversion(...)` directly with the same arguments - useful when you want to attribute to a specific session rather than the most-recent one.

> **Note**: If no flow has been presented yet, `trackConversion` logs a warning and drops the event - the backend requires non-empty flow context. Always present a flow before calling.

## Custom Components

Custom components are **dumb renderers** that expose intent. The FlowPilot editor defines what happens when events are emitted.

### Registration

Register custom components at app startup:

```swift
FlowPilot.shared?.registerCustomComponent(
    "my_paywall",
    definition: CustomComponentDefinition(
        // Declare expected inputs (for editor validation)
        inputs: [
            "user_name": .string,
            "is_premium": .boolean,
            "theme": .string,
            "show_annual": .boolean
        ],
        // Declare output events this component can emit
        outputs: [
            "purchase": OutputSchema(
                description: "User completed a purchase",
                payload: ["product_id": .string, "price": .number]
            ),
            "dismiss": OutputSchema(
                description: "User dismissed the paywall"
            )
        ],
        // Factory creates your SwiftUI view
        factory: { props, context in
            AnyView(
                MyPaywallView(
                    // Access inputs with convenient typed accessors
                    userName: props.string("user_name", default: ""),
                    isPremium: props.bool("is_premium", default: false),
                    theme: props.string("theme", default: "light"),
                    showAnnual: props.bool("show_annual", default: true),
                    onPurchase: { productId, price in
                        // Emit event - editor defines what actions happen
                        context.emit("purchase", payload: [
                            "product_id": productId,
                            "price": price
                        ])
                    },
                    onDismiss: {
                        context.emit("dismiss")
                    }
                )
            )
        }
    )
)
```

### Flow JSON Schema

Custom components use a **unified input model** - all inputs can be either bound to variables or constant values:

```json
{
  "id": "paywall_1",
  "type": "custom",
  "props": {
    "componentType": "my_paywall",
    "inputs": {
      "user_name": { "bind": "user.name" },
      "is_premium": { "bind": "user.is_premium" },
      "theme": { "value": "dark" },
      "show_annual": { "value": true }
    }
  },
  "interactions": [
    {
      "id": "on_purchase",
      "event": "purchase",
      "actions": [
        { "kind": "setVariable", "variableKey": "purchased_product", "operation": "set", "value": "event.purchase.product_id" },
        { "kind": "trackEvent", "eventKey": "paywall_purchase", "properties": {} },
        { "kind": "navigate", "targetNodeId": "success_screen" }
      ]
    },
    {
      "id": "on_dismiss",
      "event": "dismiss",
      "actions": [
        { "kind": "trackEvent", "eventKey": "paywall_dismissed" },
        { "kind": "closeFlow" }
      ]
    }
  ]
}
```

### Key Principles

1. **Unified Input Model**: All inputs use `{ "bind": "var.path" }` or `{ "value": constant }` - no separate customProps
2. **Schema-Validated Outputs**: Emitted payloads are validated against declared OutputSchema
3. **Editor-Defined Actions**: Components only emit events; the editor defines what actions happen (navigate, track, setVariable, etc.)
4. **No Direct Analytics**: Use `context.emit()` and let the editor attach `trackEvent` actions

## Error Handling

```swift
FlowPilot.shared?.setErrorCallback { error in
    switch error.code {
    case .networkError:
        print("Network error: \(error.message)")
    case .unsupportedSchemaVersion:
        print("Please update the app")
    case .placementNotFound:
        print("Placement not found")
    default:
        print("Error: \(error)")
    }
}
```

## Reliability & Fail-Safe Behavior

**Integrating FlowPilot can never take down your app.** The SDK is built so that it never crashes the host app and never strands the user on a broken or blank screen. If FlowPilot can't render, your app keeps working.

### How resolution fails safe

Resolving a placement walks a deterministic fallback chain. Each tier is tried only when the ones above it can't produce a presentable flow:

| Tier | Source | When it's used |
|------|--------|----------------|
| 0 | **Fresh cache** | A non-expired cached flow exists - rendered instantly, no network. |
| 1 | **Live network resolve** | Fetched from the API within a **hard timeout** (`resolveTimeout`, default 4s - bounds retries and backoff too, so onboarding never hangs). |
| 2 | **Stale cache (last known good)** | The live resolve failed or timed out - the last successfully-resolved flow is served, even past its freshness TTL. |
| 3 | **Bundled default flow** | No cache available - a flow JSON you shipped in the app bundle renders, so onboarding works with no network and no prior cache. |
| 4 | **Host fallback** | Nothing above worked - your own native onboarding is shown. |
| 5 | **Graceful no-op** | Even the fallback is absent - the call returns `.error` and presents nothing. No crash, no hang. |

### Guarantees

- **Cache-first render.** If a resolve fails (network, server down, timeout), the last good flow is served from cache.
- **Hard timeout.** `resolveTimeout` bounds the *entire* resolve (including retries/backoff), so onboarding can never hang on the network.
- **Graceful degradation.** A component or node type a newer flow ships but this SDK build doesn't recognize is skipped (or shown as a placeholder in DEBUG) - it never drops the rest of the screen, and a newer flow never crashes an older SDK. Newer *minor/patch* schema versions render best-effort; only a *major* schema bump is rejected.
- **No broken screens.** A flow is validated for presentability before it's shown; non-presentable flows fall through to the next tier instead of hanging on a loading spinner.

### Host fallback - UIKit

The non-throwing `presentPlacement(_:from:fallback:)` runs the whole chain and shows your native onboarding only as a last resort. It never throws:

```swift
let result = await FlowPilot.shared?.presentPlacement(
    "onboarding",
    from: self,
    fallback: { MyNativeOnboardingViewController() }   // shown only if FlowPilot has nothing to render
)
```

### Host fallback - SwiftUI

`resolveSession` returns a ready session, or `nil` when FlowPilot has nothing presentable - render your own UI in that case:

```swift
if let session = await FlowPilot.shared?.resolveSession(placementKey: "onboarding") {
    FlowPresenterView(session: session)
} else {
    MyNativeOnboardingView()
}
```

### Bundled default flows (build-time defaults)

Export a flow's JSON from the FlowPilot editor, drop it into your app target, and register it per placement - either in configuration (`bundledFlows`) or at runtime:

```swift
// From a bundle resource:
FlowPilot.shared?.registerBundledFlow(placementKey: "onboarding", resource: "OnboardingDefault")

// Or from raw JSON data:
FlowPilot.shared?.registerBundledFlow(placementKey: "onboarding", json: jsonData)
```

The bundled flow accepts either a full resolve-response payload or a bare flow definition. Renders fully offline; remote images/fonts fall back to system defaults when unreachable.

> **Analytics:** flows served from a degraded tier are tagged on every automatic event via `delivery_source` (`network`, `cache`, `stale_cache`, `bundled_default`), so offline and fallback renders are distinguishable in the dashboard.

## Tier 1 Features (Guaranteed)

These features work identically across all platforms:

| Category | Features |
|----------|----------|
| **Layout** | Vertical/horizontal stacks, spacing |
| **Size** | `auto`, `100%`, fixed pixels |
| **Padding** | Vertical and horizontal padding |
| **Margin** | All sides |
| **Background** | Solid colors |
| **Border** | Width, color (solid style) |
| **Corner Radius** | All corners equal |
| **Shadow** | Outer shadow with blur |
| **Animations** | Appear animations (opacity + translateY) |
| **Components** | text, image, button, input, toggle, progress, icon, stack, card, spacer |

## Tier 2 Features (Best-Effort)

These features are supported where possible but may degrade gracefully:

- Percentage sizing (other than 100%)
- Per-corner radius
- Layered stacks
- Advanced positioning (absolute, relative)
- Background blur
- Scale/rotate animations

## Thread Safety

The SDK is designed for concurrent access:
- API calls run on background threads
- UI updates are dispatched to the main thread
- Variable store uses locks for thread safety
- Analytics batching uses a serial queue

## Privacy

The SDK ships an Apple [privacy manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk) (`PrivacyInfo.xcprivacy`). It declares the UserDefaults required-reason API (`CA92.1`) and Product Interaction analytics, and accesses no advertising identifiers. If your app attaches a user identifier to the SDK context, reconcile that with your app's overall App Privacy declaration.

## License

FlowPilot iOS SDK is released under the MIT License. See [LICENSE](./LICENSE) for the full text.
