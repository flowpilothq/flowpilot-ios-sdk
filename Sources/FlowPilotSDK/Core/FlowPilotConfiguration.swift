import Foundation

// MARK: - Environment

/// Environment configuration for the FlowPilot SDK
public enum FlowPilotEnvironment: Sendable, Equatable {
    case development
    case staging
    case production
    case custom(url: String)

    var baseURL: String {
        switch self {
        case .development:
            return "http://localhost:8080/v1"
        case .staging:
            return "https://api.getflowpilot.io/v1"
        case .production:
            return "https://api.getflowpilot.io/v1"
        case .custom(let url):
            return url
        }
    }

    var cacheTTL: TimeInterval {
        switch self {
        case .development:
            return 0 // No caching in development
        case .staging:
            return 60 // 60 seconds
        case .production:
            return 300 // 5 minutes
        case .custom:
            return 0 // No caching for custom URLs
        }
    }

    var debugLoggingEnabled: Bool {
        switch self {
        case .development:
            return true
        case .staging:
            return true
        case .production:
            return false
        case .custom:
            return true // Enable debug logging for custom URLs
        }
    }

    var name: String {
        switch self {
        case .development:
            return "development"
        case .staging:
            return "staging"
        case .production:
            return "production"
        case .custom(let url):
            return "custom(\(url))"
        }
    }
}

// MARK: - Log Level

/// Log level for SDK debugging
public enum FlowPilotLogLevel: Int, Comparable, Sendable {
    case none = 0
    case error = 1
    case warn = 2
    case info = 3
    case debug = 4
    case verbose = 5

    public static func < (lhs: FlowPilotLogLevel, rhs: FlowPilotLogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - SDK Context

/// Context values provided by the host app for variable resolution
public typealias SDKContext = [String: Any]

// MARK: - Callbacks

/// Analytics event callback
public typealias AnalyticsCallback = (AnalyticsEvent) -> Void

/// Flow completion callback
public typealias FlowCompletionCallback = (FlowResult) -> Void

/// Flow dismissal callback
public typealias FlowDismissalCallback = (String) -> Void

/// Error callback
public typealias ErrorCallback = (FlowPilotError) -> Void

// MARK: - Prefetch Media Strategy

/// How aggressively launch prefetch warms a flow's images into `ImageCache`.
///
/// Used by `FlowPilotConfiguration.prefetchMediaStrategy` to bound what the
/// background launch prefetch downloads, and to bound the screen window when a
/// `prefetch(..., warmMedia: true)` call opts into media warming.
public enum PrefetchMediaStrategy: Sendable {
    /// Warm the flow JSON + custom fonts only; download no images.
    case none

    /// Also warm the first screen's images and persistent-zone images
    /// (navigation bar / footer / overlay). The default: it removes first-screen
    /// image pop-in while bounding network and memory to what's visible on
    /// arrival, so launch prefetch stays cheap.
    case firstScreen

    /// Also warm every screen's images. Use only for short flows where pulling
    /// all art up front at launch is an acceptable bandwidth trade.
    case allScreens
}

// MARK: - Configuration

/// Configuration for initializing the FlowPilot SDK
public struct FlowPilotConfiguration: Sendable {
    // MARK: Required

    /// Workspace API key
    public let apiKey: String

    /// App identifier
    public let appId: String

    // MARK: Environment

    /// SDK environment
    public let environment: FlowPilotEnvironment

    // MARK: Optional Context

    /// Initial SDK context for variable resolution
    public let context: SDKContext?

    // MARK: Optional Caching

    /// Whether caching is enabled (default: true)
    public let cachingEnabled: Bool

    /// Custom cache directory (default: platform-specific)
    public let cacheDirectory: String?

    // MARK: Resilience

    /// Hard wall-clock deadline for resolving a placement, in seconds (default: 4).
    ///
    /// Bounds the *entire* resolve — including retries and rate-limit backoff —
    /// so onboarding never hangs waiting on the network. If the deadline is hit,
    /// the SDK falls back to the last-known-good cache, then a bundled default
    /// flow, then the host's fallback. Set higher only if your audience is on
    /// consistently slow networks.
    public let resolveTimeout: TimeInterval

    /// Build-time default flows, keyed by placement key.
    ///
    /// Each value is the base name of a JSON resource in the app's main bundle
    /// (e.g. `"OnboardingDefault"` for `OnboardingDefault.json`). The JSON is
    /// the payload exported from the FlowPilot editor. When a live resolve fails
    /// and no cache is available, the SDK renders the bundled flow so onboarding
    /// works with no network and no prior cache.
    ///
    /// For in-memory payloads or custom bundles, use
    /// `FlowPilot.registerBundledFlow(...)` at runtime instead.
    public let bundledFlows: [String: String]

    /// Offline image/font assets for bundled flows, keyed by placement key.
    ///
    /// Declares where each bundled flow's images and fonts live (an exported
    /// `.flowassets` folder, typically) so the bundled-default tier renders fully
    /// offline — no remote image / font requests. Optional: a bundled flow with
    /// no assets here still renders, just with remote images / system-font
    /// fallback when offline.
    public let bundledFlowAssets: [String: BundledFlowAssets]

    // MARK: Media Preloading

    /// Whether to preload media content when a flow is initialized (default: true)
    /// When enabled, images and media are downloaded in screen order priority
    /// so users don't see loading states while navigating through screens
    public let mediaPreloadingEnabled: Bool

    /// Maximum memory cache size for images in bytes (default: 50MB)
    public let imageMemoryCacheSize: Int

    /// Maximum disk cache size for images in bytes (default: 200MB)
    public let imageDiskCacheSize: Int

    // MARK: Launch Prefetch

    /// Placements to prefetch automatically, once, right after `configure(...)`.
    ///
    /// Each declared placement is resolved and warmed in the background at
    /// utility priority, fire-and-forget, so it never blocks startup: the flow
    /// JSON (memory + disk cache) and custom fonts are warmed, plus — per
    /// `prefetchMediaStrategy` — first-screen (or all-screen) images. A later
    /// `presentPlacement` for a warmed placement then hits the cache (Tier 0)
    /// with no network round-trip.
    ///
    /// Defaults to `[]` (no automatic prefetch). No-op when
    /// `cachingEnabled == false` (nothing would be retained); a warning is logged
    /// in that case.
    ///
    /// - Important: Warmed flows only survive as long as their freshness TTL
    ///   (driven by the resolve response's `cacheTtlSeconds`). The
    ///   `.development` and `.custom` environments intentionally disable HTTP
    ///   caching, so against a backend that returns a `0` TTL a warmed entry
    ///   expires immediately and launch prefetch is effectively a no-op. Use
    ///   `.staging` / `.production` (or a backend that returns a non-zero TTL) to
    ///   see the benefit.
    public let prefetchOnLaunch: [String]

    /// How aggressively launch prefetch warms images (default: `.firstScreen`).
    ///
    /// Governs the background launch prefetch declared via `prefetchOnLaunch`,
    /// and bounds the screen window when an explicit `prefetch(..., warmMedia:
    /// true)` call opts into media warming. Left at `.firstScreen`, only the
    /// first screen's and persistent-zone images are warmed. A bare
    /// `prefetch([...])` (no `warmMedia`) still warms no media, preserving
    /// existing behavior.
    public let prefetchMediaStrategy: PrefetchMediaStrategy

    // MARK: Optional Debugging

    /// Debug mode override
    public let debugMode: Bool?

    /// Log level
    public let logLevel: FlowPilotLogLevel

    // MARK: Error Reporting

    /// Opt out of the SDK's internal error reporting (default: `false`).
    ///
    /// When the SDK hits one of its OWN internal failures (a failed flow
    /// resolve, an invalid flow schema, a coerced presentation fallback) it
    /// posts a small, bounded, fire-and-forget diagnostic to FlowPilot so we can
    /// fix it. It is **not** a crash reporter: it installs no signal/exception
    /// handlers, never blocks or throws into your code, never retries, dedupes
    /// identical reports, and caps the total per launch. Set this to `true` to
    /// disable it entirely — the reporter then becomes a no-op.
    public let disableErrorReporting: Bool

    // MARK: Initialization

    public init(
        apiKey: String,
        appId: String,
        environment: FlowPilotEnvironment = .production,
        context: SDKContext? = nil,
        cachingEnabled: Bool = true,
        cacheDirectory: String? = nil,
        resolveTimeout: TimeInterval = 4.0,
        bundledFlows: [String: String] = [:],
        bundledFlowAssets: [String: BundledFlowAssets] = [:],
        mediaPreloadingEnabled: Bool = true,
        imageMemoryCacheSize: Int = 50 * 1024 * 1024,
        imageDiskCacheSize: Int = 200 * 1024 * 1024,
        debugMode: Bool? = nil,
        logLevel: FlowPilotLogLevel = .error,
        prefetchOnLaunch: [String] = [],
        prefetchMediaStrategy: PrefetchMediaStrategy = .firstScreen,
        disableErrorReporting: Bool = false
    ) {
        self.apiKey = apiKey
        self.appId = appId
        self.environment = environment
        self.context = context
        self.cachingEnabled = cachingEnabled
        self.cacheDirectory = cacheDirectory
        self.resolveTimeout = max(0.5, resolveTimeout)
        self.bundledFlows = bundledFlows
        self.bundledFlowAssets = bundledFlowAssets
        self.mediaPreloadingEnabled = mediaPreloadingEnabled
        self.imageMemoryCacheSize = imageMemoryCacheSize
        self.imageDiskCacheSize = imageDiskCacheSize
        self.debugMode = debugMode
        self.logLevel = logLevel
        self.prefetchOnLaunch = prefetchOnLaunch
        self.prefetchMediaStrategy = prefetchMediaStrategy
        self.disableErrorReporting = disableErrorReporting
    }
}

// MARK: - Presentation Options

/// Options for presenting a flow
public struct PresentationOptions: Sendable {
    /// Additional context for this presentation only
    public let additionalContext: SDKContext?

    /// Presentation style override
    public let presentationStyle: PresentationStyle?

    /// Whether to animate presentation
    public let animated: Bool

    public init(
        additionalContext: SDKContext? = nil,
        presentationStyle: PresentationStyle? = nil,
        animated: Bool = true
    ) {
        self.additionalContext = additionalContext
        self.presentationStyle = presentationStyle
        self.animated = animated
    }
}

/// Presentation style for flows
public enum PresentationStyle: String, Sendable {
    case fullScreen
    case modal
    case bottomSheet
}

// MARK: - Flow Result

/// Result of a flow presentation
public struct FlowResult: Sendable {
    /// How the flow ended
    public let outcome: FlowOutcome

    /// Final variable values
    public let finalVariables: [String: VariableValue]

    /// Screens visited during the flow
    public let screensVisited: [String]

    /// Duration of the flow in milliseconds
    public let durationMs: Int

    /// Experiment assignments made during this session
    public let experimentAssignments: [String: String]

    /// Error if outcome is .error
    public let error: FlowPilotError?

    public init(
        outcome: FlowOutcome,
        finalVariables: [String: VariableValue] = [:],
        screensVisited: [String] = [],
        durationMs: Int = 0,
        experimentAssignments: [String: String] = [:],
        error: FlowPilotError? = nil
    ) {
        self.outcome = outcome
        self.finalVariables = finalVariables
        self.screensVisited = screensVisited
        self.durationMs = durationMs
        self.experimentAssignments = experimentAssignments
        self.error = error
    }
}

/// Outcome of a flow presentation
public enum FlowOutcome: String, Sendable {
    case completed
    case dismissed
    case error
}

// MARK: - Placement Info

/// Information about a placement
public struct PlacementInfo: Sendable {
    public let placementId: String
    public let placementKey: String
    public let willShow: Bool
    public let flowId: String?
    public let experimentId: String?
    public let variantId: String?
}
