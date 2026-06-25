import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Prefetch Outcome

/// The per-placement result of a `prefetch(...)` (or `isPlacementReady`) call.
///
/// `prefetch` never throws — it reports what happened for each placement here so
/// callers can tell, without a wasted extra round-trip, which placements are warm
/// and ready, which the backend said should show nothing, and which failed.
public struct PrefetchOutcome: Sendable {
    /// What happened when warming this placement.
    public enum State: Sendable {
        /// A presentable flow is cached and ready to show.
        ///
        /// `fromCache` is `true` when the flow came from a local cached copy
        /// (a fresh Tier-0 hit or a last-known-good stale entry) without a fresh
        /// successful network resolve, and `false` when it was freshly resolved
        /// from the network or served from a bundled default.
        case warmed(fromCache: Bool)
        /// The resolve succeeded but the backend returned no flow for this
        /// placement (targeting not met, no flow assigned, etc.). Nothing to warm.
        case noFlow
        /// The resolve failed (network/timeout/invalid schema) and no fallback was
        /// available. Nothing was warmed.
        case failed(FlowPilotError)
    }

    /// The placement key this outcome is for.
    public let placementKey: String

    /// What happened warming the placement.
    public let state: State

    /// Whether first-screen (or all-screen) media was warmed into `ImageCache`
    /// as part of this prefetch. Always `false` until media warming is requested
    /// and the flow is presentable.
    public let mediaWarmed: Bool

    /// Convenience: whether a presentable flow is now cached for this placement.
    public var isWarmed: Bool {
        if case .warmed = state { return true }
        return false
    }
}

// MARK: - FlowPilot

/// Main entry point for the FlowPilot SDK
public final class FlowPilot: @unchecked Sendable {
    // MARK: - Singleton

    /// Shared instance of FlowPilot
    public private(set) static var shared: FlowPilot?

    // MARK: - Configuration

    private let configuration: FlowPilotConfiguration
    private var sdkContext: SDKContext

    // MARK: - Services

    private let apiClient: APIClient
    private let resolveService: ResolveServing
    private let eventService: EventService
    private let flowCache: FlowCache
    private let bundledFlowProvider: BundledFlowProvider

    /// Bounded, fire-and-forget reporter for the SDK's own internal failures.
    /// A no-op when `configuration.disableErrorReporting` is set.
    private let errorReporter: ErrorReporter

    /// Dedupes concurrent network resolves for the same cache key so a prefetch
    /// and a present-time resolve (or two presents) share one round-trip.
    private let resolveCoalescer = ResolveCoalescer()

    // MARK: - Registries

    internal var customComponents: [String: CustomComponentDefinition] = [:]
    internal var customScreens: [String: CustomScreenDefinition] = [:]
    private let registryLock = NSLock()

    // MARK: - Callbacks

    private var analyticsCallback: AnalyticsCallback?
    private var errorCallback: ErrorCallback?

    // MARK: - Active Session Tracking

    /// Strong reference to the most-recently-started session. Used by
    /// `trackConversion` so revenue events emitted after the flow returns
    /// (e.g. from an Apple IAP callback fired seconds after dismiss) can
    /// still be attributed to the originating flow.
    ///
    /// Held strongly — not weak — because the imperative `presentPlacement`
    /// API doesn't return a session reference to the host app, so a weak ref
    /// would deallocate the moment `presentPlacement` returns and we'd lose
    /// attribution. Memory footprint is bounded: only the latest session is
    /// retained, and it's replaced on the next `createSession` /
    /// `presentPlacement` call.
    private var activeSession: FlowSession?
    private let activeSessionLock = NSLock()

    // MARK: - Initialization

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - configuration: The SDK configuration.
    ///   - resolveService: The resolve backend. Defaults to the real
    ///     `ResolveService` built from `configuration`; tests inject a mock
    ///     conforming to `ResolveServing` to count/intercept network resolves.
    internal init(
        configuration: FlowPilotConfiguration,
        resolveService: ResolveServing? = nil
    ) {
        self.configuration = configuration
        self.sdkContext = configuration.context ?? [:]

        // Initialize API client
        self.apiClient = APIClient(
            baseURL: configuration.environment.baseURL,
            apiKey: configuration.apiKey,
            appId: configuration.appId
        )

        // Initialize services
        self.resolveService = resolveService ?? ResolveService(apiClient: apiClient, appId: configuration.appId)
        self.eventService = EventService(apiClient: apiClient, appId: configuration.appId)

        // Initialize internal error reporter (no-op when opted out). Reuses the
        // same base URL + API key as every other request; posts to the backend's
        // `/apps/{appId}/sdk-errors` endpoint, fire-and-forget and bounded.
        self.errorReporter = ErrorReporter(
            enabled: !configuration.disableErrorReporting,
            baseURL: configuration.environment.baseURL,
            apiKey: configuration.apiKey,
            appId: configuration.appId,
            environmentName: configuration.environment.name
        )

        // Initialize cache
        self.flowCache = FlowCache(
            enabled: configuration.cachingEnabled,
            cacheDirectory: configuration.cacheDirectory
        )

        // Initialize bundled (build-time default) flow provider and register
        // any flows declared in the configuration as main-bundle JSON resources.
        self.bundledFlowProvider = BundledFlowProvider()
        for (placementKey, resourceName) in configuration.bundledFlows {
            self.bundledFlowProvider.registerResource(
                placementKey: placementKey,
                resource: resourceName,
                withExtension: "json",
                in: .main
            )
        }
        // Offline image/font assets for bundled flows, so the bundled-default
        // tier can render with no network at all.
        for (placementKey, assets) in configuration.bundledFlowAssets {
            self.bundledFlowProvider.register(placementKey: placementKey, assets: assets)
        }

        // Configure image cache sizes
        ImageCache.shared.maxMemoryCacheSize = configuration.imageMemoryCacheSize
        ImageCache.shared.maxDiskCacheSize = configuration.imageDiskCacheSize

        // Set log level
        Logger.shared.setLogLevel(configuration.logLevel)

        Logger.shared.info("FlowPilot SDK initialized - v\(FlowPilotSDK.version)")
        Logger.shared.debug("Media preloading: \(configuration.mediaPreloadingEnabled ? "enabled" : "disabled")")
    }

    // MARK: - Configuration

    /// Configure the FlowPilot SDK.
    ///
    /// If `configuration.prefetchOnLaunch` is non-empty, the declared placements
    /// are warmed in the background once, at utility priority, immediately after
    /// the shared instance is assigned. This is fire-and-forget: it never blocks
    /// `configure` and never throws. See `prefetchOnLaunch` /
    /// `prefetchMediaStrategy` for what gets warmed and the dev/TTL caveat.
    public static func configure(_ configuration: FlowPilotConfiguration) {
        // Validate API key format
        guard configuration.apiKey.hasPrefix("fp_") else {
            Logger.shared.error("Invalid API key format")
            return
        }

        let instance = FlowPilot(configuration: configuration)
        shared = instance

        // Config-driven launch prefetch: warm the declared placements in the
        // background so a later present is instant (Tier 0). Fire-and-forget at
        // utility priority so it never contends with app startup. Only spawned
        // when placements are declared; the caching-disabled guard lives in
        // `runLaunchPrefetch` (which also warns).
        if !configuration.prefetchOnLaunch.isEmpty {
            Task(priority: .utility) {
                await instance.runLaunchPrefetch()
            }
        }
    }

    /// Update the SDK context at runtime
    public func updateContext(_ context: SDKContext) {
        for (key, value) in context {
            sdkContext[key] = value
        }
        Logger.shared.debug("SDK context updated with \(context.count) values")
    }

    /// Set the analytics callback
    public func setAnalyticsCallback(_ callback: @escaping AnalyticsCallback) {
        analyticsCallback = callback
    }

    /// Set the error callback
    public func setErrorCallback(_ callback: @escaping ErrorCallback) {
        errorCallback = callback
    }

    /// Central sink for the SDK's OWN internal failures.
    ///
    /// Does two things, both best-effort and non-throwing:
    /// 1. Hands the error to the bounded, fire-and-forget `ErrorReporter` (which
    ///    is a no-op when the customer opted out via `disableErrorReporting`).
    /// 2. Surfaces the coerced `FlowPilotError` to the host's `errorCallback`, if
    ///    one is set, so the integrating app can observe failures too.
    ///
    /// This must never throw or block the failing code path; call it from a
    /// `catch` and continue. It deliberately does NOT log via `Logger.error` to
    /// avoid any feedback loop — call sites already log at the appropriate level.
    ///
    /// - Parameters:
    ///   - error: The failure to report (a `FlowPilotError` is mapped to its
    ///     `code` + `context`; any other `Error` is reported with its type name).
    ///   - code: Optional explicit error code override (defaults to the
    ///     `FlowPilotError`'s code when available).
    ///   - placementKey: Optional placement context added as `placement_id`.
    ///   - level: `"error"` (default) or `"warning"`.
    func reportInternal(
        _ error: Error,
        code: String? = nil,
        placementKey: String? = nil,
        level: String = "error"
    ) {
        var extra: [String: String]? = nil
        if let placementKey = placementKey {
            extra = ["placement_id": placementKey]
        }
        errorReporter.report(error, code: code, level: level, extraContext: extra)

        if let callback = errorCallback {
            let fpError = error as? FlowPilotError ?? FlowPilotError.networkError(error)
            callback(fpError)
        }
    }

    /// Register the most-recently-started session. Internal — called by the
    /// SDK whenever a session is created so `trackConversion` can find it.
    private func setActiveSession(_ session: FlowSession) {
        activeSessionLock.lock()
        activeSession = session
        activeSessionLock.unlock()
    }

    // MARK: - Placement API

    /// Check if a placement is ready to show.
    ///
    /// Routes through the same cache-populating path as `prefetch`, so the
    /// resolve it performs is **not** wasted: a presentable flow is left warm in
    /// the cache and a subsequent `presentPlacement` hits Tier 0 (no second
    /// round-trip). Returns `true` whenever a presentable flow is available
    /// (fresh cache, live resolve, last-known-good, or bundled default), `false`
    /// when the backend says there's nothing to show or the resolve failed.
    public func isPlacementReady(_ placementKey: String) async -> Bool {
        return await warm(placementKey: placementKey, warmMedia: false).isWarmed
    }

    #if canImport(UIKit)
    /// Present a flow from a placement
    @MainActor
    public func presentPlacement(
        _ placementKey: String,
        from viewController: UIViewController,
        options: PresentationOptions? = nil,
        completion: ((FlowResult) -> Void)? = nil
    ) async throws {
        let (flow, deliverySource) = try await resolveDelivery(placementKey)

        // Merge additional context
        var mergedContext = sdkContext
        if let additional = options?.additionalContext {
            for (key, value) in additional {
                mergedContext[key] = value
            }
        }

        // Create session
        let session = FlowSession(
            flow: flow,
            placementId: placementKey,
            sdkContext: mergedContext,
            eventService: eventService,
            analyticsCallback: analyticsCallback,
            preloadMedia: configuration.mediaPreloadingEnabled,
            deliverySource: deliverySource
        )
        setActiveSession(session)

        // Present using standard UIKit presentation
        let hostingController = FlowHostingController(session: session)
        viewController.present(hostingController, animated: options?.animated ?? true)

        // Wait for result
        let result = await session.waitForCompletion()

        // Dismiss the controller
        hostingController.dismiss(animated: options?.animated ?? true)
        completion?(result)
    }

    /// Present a placement and return the result
    @MainActor
    public func presentPlacement(
        _ placementKey: String,
        from viewController: UIViewController,
        options: PresentationOptions? = nil
    ) async throws -> FlowResult {
        let (flow, deliverySource) = try await resolveDelivery(placementKey)

        var mergedContext = sdkContext
        if let additional = options?.additionalContext {
            for (key, value) in additional {
                mergedContext[key] = value
            }
        }

        let session = FlowSession(
            flow: flow,
            placementId: placementKey,
            sdkContext: mergedContext,
            eventService: eventService,
            analyticsCallback: analyticsCallback,
            preloadMedia: configuration.mediaPreloadingEnabled,
            deliverySource: deliverySource
        )
        setActiveSession(session)

        let hostingController = FlowHostingController(session: session)
        viewController.present(hostingController, animated: options?.animated ?? true)

        let result = await session.waitForCompletion()

        // Dismiss the controller
        hostingController.dismiss(animated: options?.animated ?? true)

        return result
    }

    /// Present a placement that **never throws** — the API that backs the
    /// guarantee that integrating FlowPilot can't take down your app.
    ///
    /// Walks the full fallback chain: fresh cache → live resolve (hard timeout)
    /// → stale cache → bundled default flow. If *none* of those yield a
    /// presentable flow, it presents your `fallback` view controller (your app's
    /// own native onboarding) instead. It always returns a `FlowResult`; it
    /// never throws and never leaves the user on a broken or blank screen.
    ///
    /// - Parameters:
    ///   - placementKey: The placement to resolve.
    ///   - viewController: The presenting view controller.
    ///   - fallback: Produces your native onboarding UI, shown only when
    ///     FlowPilot has nothing presentable. Invoked on the main actor.
    ///   - options: Optional presentation options.
    @MainActor
    @discardableResult
    public func presentPlacement(
        _ placementKey: String,
        from viewController: UIViewController,
        fallback: @escaping @MainActor () -> UIViewController,
        options: PresentationOptions? = nil
    ) async -> FlowResult {
        do {
            let (flow, deliverySource) = try await resolveDelivery(placementKey)

            var mergedContext = sdkContext
            if let additional = options?.additionalContext {
                for (key, value) in additional { mergedContext[key] = value }
            }

            let session = FlowSession(
                flow: flow,
                placementId: placementKey,
                sdkContext: mergedContext,
                eventService: eventService,
                analyticsCallback: analyticsCallback,
                preloadMedia: configuration.mediaPreloadingEnabled,
                deliverySource: deliverySource
            )
            setActiveSession(session)

            let hostingController = FlowHostingController(session: session)
            viewController.present(hostingController, animated: options?.animated ?? true)
            let result = await session.waitForCompletion()
            hostingController.dismiss(animated: options?.animated ?? true)
            return result
        } catch {
            // Tier 4: host fallback. Present the app's own native onboarding.
            let fpError = error as? FlowPilotError ?? FlowPilotError.networkError(error)
            Logger.shared.warn("presentPlacement: no FlowPilot flow available (\(fpError)). Presenting host fallback.")
            // Report the coerced error before falling back to the host's native
            // onboarding. (Deduped against any report `resolveDelivery` already
            // emitted for the same failure within the dedupe window.)
            reportInternal(fpError, placementKey: placementKey)
            let fallbackVC = fallback()
            viewController.present(fallbackVC, animated: options?.animated ?? true)
            return FlowResult(outcome: .error, error: fpError)
        }
    }
    #endif

    // MARK: - Flow Resolution

    /// Resolve a placement into a presentable flow, walking the fail-safe
    /// fallback chain and reporting which tier produced the result.
    ///
    /// ```
    /// Tier 0  Fresh cache hit            → present instantly, no network
    /// Tier 1  Network within deadline    → validate, refresh cache, present
    /// Tier 2  Stale cache (last good)    → present if the resolve failed/timed out
    /// Tier 3  Bundled default flow       → present the build-time offline default
    /// (Tier 4 host fallback / Tier 5 no-op are handled by the caller via `throw`.)
    /// ```
    ///
    /// Throws only when no tier yielded a presentable flow, so the caller can run
    /// the host's native fallback or complete with `.error` — never a crash,
    /// never a hang, never a blank screen.
    private func resolveDelivery(_ placementKey: String) async throws -> (flow: ResolvedFlow, source: FlowDeliverySource) {
        // Identity-aware cache key: ties cache hits to the user + attributes this
        // resolve is personalized by, so a flow cached under one identity is never
        // served to another (wrong targeting / wrong A/B variant).
        let fingerprint = currentFingerprint()

        // Tier 0: fresh cache. When the served entry is close to expiry, also
        // kick a background refresh (stale-while-revalidate) so the next caller
        // gets a fresh copy without anyone waiting on the network. The refresh is
        // fire-and-forget and never changes what *this* present shows.
        if let fresh = flowCache.getFreshFlow(placementId: placementKey, fingerprint: fingerprint),
           fresh.flow.validateForPresentation() {
            Logger.shared.debug("Using fresh cached flow for placement: \(placementKey)")
            await loadFonts(for: fresh.flow)
            revalidateIfNeeded(
                placementKey: placementKey,
                fingerprint: fingerprint,
                servedFlow: fresh.flow,
                ttlRemaining: fresh.ttlRemaining
            )
            return (fresh.flow, .cache)
        }

        // Tier 1: live network resolve, coalesced across concurrent callers and
        // bounded by a hard wall-clock deadline. Cache refresh + font loading run
        // *inside* the coalesced resolve (see `resolveWithDeadline`) so they still
        // complete — populating the cache for the next caller — even when this
        // caller times out and falls through to a fallback tier.
        do {
            let flow = try await resolveWithDeadline(placementKey, fingerprint: fingerprint)
            return (flow, .network)
        } catch {
            Logger.shared.warn("Resolve failed for placement '\(placementKey)': \(error). Attempting fallbacks.")

            // Tier 2: stale cache (last known good).
            if let stale = flowCache.getStaleFlow(placementId: placementKey, fingerprint: fingerprint), stale.validateForPresentation() {
                Logger.shared.info("Serving last-known-good cached flow for placement '\(placementKey)'")
                await loadFonts(for: stale)
                return (stale, .staleCache)
            }

            // Tier 3: bundled build-time default flow.
            if let bundled = bundledFlowProvider.flow(for: placementKey) {
                Logger.shared.info("Serving bundled default flow for placement '\(placementKey)'")
                // Seed offline image/font assets (if the dev shipped them) BEFORE
                // loading fonts so the CDN pass finds them already registered, and
                // before returning so the first paint renders from local bytes.
                // Best-effort: seeding never throws, a missing asset just degrades
                // to a blank image / system font.
                await bundledFlowProvider.seedAssets(for: placementKey, flow: bundled)
                await loadFonts(for: bundled)
                return (bundled, .bundledDefault)
            }

            // Nothing presentable across every tier — this is a genuine internal
            // failure (live resolve failed AND no stale cache / bundled default).
            // Report it once here (covers both resolve-network failures and a
            // bubbled-up `.invalidFlowSchema` decode failure, with whatever
            // status_code/component context the error already carries) before
            // propagating so the caller can run the host fallback (Tier 4) or
            // complete gracefully (Tier 5).
            reportInternal(error, placementKey: placementKey)
            throw error
        }
    }

    /// Run the network resolve, coalesced across concurrent callers and bounded by
    /// a hard wall-clock deadline.
    ///
    /// The actual resolve runs once per `placement:<id>:<fingerprint>` key via
    /// `ResolveCoalescer`: a prefetch and a present-time resolve (or two presents)
    /// for the same placement + identity share a single round-trip. The shared
    /// task also refreshes the cache and loads fonts, so that work completes — and
    /// benefits the next caller — even if *this* caller times out.
    ///
    /// `awaitValue` bounds only the current caller's wait to `resolveTimeout`
    /// (including the API client's retries / rate-limit backoff, so onboarding can
    /// never hang on the network). Critically, hitting the deadline does **not**
    /// cancel the shared resolve — the caller just walks away to a fallback tier
    /// while the resolve keeps populating the cache in the background.
    private func resolveWithDeadline(_ placementKey: String, fingerprint: String) async throws -> ResolvedFlow {
        let key = placementKey + ":" + fingerprint
        let shared = await resolveCoalescer.sharedTask(key: key) {
            let flow = try await self.performNetworkResolve(placementKey)
            // Cache + fonts inside the shared task so a timed-out caller still
            // leaves the cache warm for the next one. Both are idempotent.
            self.flowCache.setFlow(flow, placementId: placementKey, fingerprint: fingerprint)
            await self.loadFonts(for: flow)
            return flow
        }
        return try await awaitValue(of: shared, timeout: configuration.resolveTimeout)
    }

    /// Fraction of a flow's freshness TTL below which a Tier-0 cache hit triggers
    /// a background refresh. At `0.2`, a served entry within the last 20% of its
    /// TTL is silently refreshed so the next caller gets a fresh copy.
    private static let revalidateThreshold = 0.2

    /// Stale-while-revalidate: when a fresh Tier-0 cache hit is close to expiry,
    /// kick a background, coalesced resolve to refresh the cache for the next
    /// caller. Fire-and-forget at utility priority — the current present is
    /// already served from cache, so this never blocks it and never changes what
    /// it shows. The refresh shares `ResolveCoalescer`, so it folds into any
    /// concurrent present-time resolve, and reuses the same `setFlow` + `loadFonts`
    /// side effects. Failures are intentionally swallowed: the existing entry
    /// stays until it genuinely expires, at which point Tier 1/2 take over.
    private func revalidateIfNeeded(
        placementKey: String,
        fingerprint: String,
        servedFlow: ResolvedFlow,
        ttlRemaining: TimeInterval
    ) {
        let ttl = TimeInterval(servedFlow.cacheTtlSeconds)
        // A non-positive TTL is non-cacheable — there's no freshness window to
        // revalidate within (and it wouldn't have been a fresh hit anyway).
        guard ttl > 0 else { return }
        guard ttlRemaining < ttl * Self.revalidateThreshold else { return }

        let key = placementKey + ":" + fingerprint
        Logger.shared.debug("SWR: '\(placementKey)' is near expiry (\(Int(ttlRemaining))s left of \(Int(ttl))s); refreshing in background.")
        Task(priority: .utility) {
            do {
                _ = try await self.resolveCoalescer.resolve(key: key) {
                    let refreshed = try await self.performNetworkResolve(placementKey)
                    self.flowCache.setFlow(refreshed, placementId: placementKey, fingerprint: fingerprint)
                    await self.loadFonts(for: refreshed)
                    return refreshed
                }
                Logger.shared.debug("SWR: background refresh for '\(placementKey)' completed.")
            } catch {
                Logger.shared.debug("SWR: background refresh for '\(placementKey)' failed: \(error)")
            }
        }
    }

    /// One network resolve attempt: call the API, decode, and validate that the
    /// result is actually presentable. Caching and font loading are handled by
    /// the caller so they apply uniformly across every fallback tier.
    private func performNetworkResolve(_ placementKey: String) async throws -> ResolvedFlow {
        Logger.shared.debug("Resolving placement from API: \(placementKey)")
        let response = try await resolveService.resolvePlacement(
            placementId: placementKey,
            userId: SessionManager.shared.userId,
            sessionId: SessionManager.shared.sessionId,
            attributes: buildAttributes()
        )
        Logger.shared.debug("API response received - hasFlow: \(response.hasFlow), flowId: \(response.flowId ?? "nil")")

        guard response.hasFlow else {
            throw FlowPilotError(code: .flowNotFound, message: "No flow for placement: \(placementKey)")
        }

        let flow = try ResolvedFlow(from: response)
        try flow.validateSchemaVersion()

        guard flow.validateForPresentation() else {
            throw FlowPilotError(
                code: .invalidFlowSchema,
                message: "Resolved flow for placement '\(placementKey)' has no presentable screen"
            )
        }

        Logger.shared.debug("ResolvedFlow created and validated - flowId: \(flow.flowId), schema: \(flow.schemaVersion)")
        return flow
    }

    /// Register custom fonts for a flow before presenting. Font registration is
    /// process-scoped, so this runs for cached/stale/bundled flows too. Failures
    /// are non-fatal — the flow renders with system-font fallback.
    private func loadFonts(for flow: ResolvedFlow) async {
        guard let fonts = flow.fonts, !fonts.isEmpty else { return }
        await FontManager.shared.loadFonts(fonts)
    }

    // MARK: - Prefetching

    /// Prefetch placements so a later presentation is instant.
    ///
    /// Warms each placement's flow JSON (memory + disk cache) and custom fonts by
    /// running the same resolve path a present would, so a subsequent
    /// `presentPlacement` hits Tier 0 (no network). Runs all placements
    /// concurrently and **never throws** — the returned map reports a
    /// `PrefetchOutcome` per placement (warmed / no-flow / failed) so callers can
    /// see exactly what is warm without a second round-trip.
    ///
    /// Input keys are de-duplicated. When `cachingEnabled == false` nothing is
    /// retained, so the call is skipped (and logged) and an empty map is returned.
    ///
    /// - Parameters:
    ///   - placementKeys: The placements to warm.
    ///   - warmMedia: Whether to also warm images into `ImageCache`. Pass `true`
    ///     to warm them (bounded by `prefetchMediaStrategy` — first screen unless
    ///     `.allScreens`). `nil` (the default) warms **no** media, so a bare
    ///     `prefetch([...])` keeps its established JSON + fonts behavior; opt in
    ///     explicitly with `warmMedia: true`. (Launch prefetch declared via
    ///     `prefetchOnLaunch` derives this from `prefetchMediaStrategy` instead.)
    /// - Returns: A map from placement key to its `PrefetchOutcome`.
    @discardableResult
    public func prefetch(
        _ placementKeys: [String],
        warmMedia: Bool? = nil
    ) async -> [String: PrefetchOutcome] {
        // Nothing would be retained with caching off — skip and warn.
        guard configuration.cachingEnabled else {
            Logger.shared.warn("prefetch: caching is disabled; nothing to warm. Skipping \(placementKeys.count) placement(s).")
            return [:]
        }

        // De-dupe input keys, preserving first-seen order.
        var seen = Set<String>()
        let uniqueKeys = placementKeys.filter { seen.insert($0).inserted }
        guard !uniqueKeys.isEmpty else { return [:] }

        let shouldWarmMedia = resolveWarmMedia(warmMedia)

        return await withTaskGroup(of: (String, PrefetchOutcome).self) { group in
            for key in uniqueKeys {
                group.addTask {
                    let outcome = await self.warm(placementKey: key, warmMedia: shouldWarmMedia)
                    return (key, outcome)
                }
            }

            var results: [String: PrefetchOutcome] = [:]
            for await (key, outcome) in group {
                results[key] = outcome
            }
            return results
        }
    }

    /// Run the config-driven launch prefetch declared via
    /// `configuration.prefetchOnLaunch`.
    ///
    /// Factored out of `configure(...)` so the static entry point can fire it
    /// fire-and-forget while tests can `await` it deterministically. Warms the
    /// declared placements, deriving media warming from
    /// `configuration.prefetchMediaStrategy` (so launch prefetch warms
    /// first-screen images by default, unlike a bare `prefetch([...])`). No-ops
    /// (and warns) when caching is disabled or nothing is declared. Never throws.
    @discardableResult
    internal func runLaunchPrefetch() async -> [String: PrefetchOutcome] {
        let keys = configuration.prefetchOnLaunch
        guard configuration.cachingEnabled else {
            if !keys.isEmpty {
                Logger.shared.warn("prefetchOnLaunch declared \(keys.count) placement(s) but caching is disabled; skipping launch prefetch (nothing would be retained).")
            }
            return [:]
        }
        guard !keys.isEmpty else { return [:] }

        // De-dupe so the batch round-trip and the per-placement warm pass agree
        // on the set.
        var seen = Set<String>()
        let uniqueKeys = keys.filter { seen.insert($0).inserted }

        Logger.shared.debug("Launch prefetch: warming \(uniqueKeys.count) placement(s) at utility priority.")

        // Batch fast-path: resolve every declared placement in one round-trip and
        // seed the cache, so the warm pass below hits Tier 0 for each (no extra
        // network). Best-effort — on failure the warm pass falls back to
        // per-placement resolves.
        await batchSeedCache(uniqueKeys)

        let warmMedia = configuration.prefetchMediaStrategy != .none
        return await prefetch(uniqueKeys, warmMedia: warmMedia)
    }

    /// Resolve every launch-prefetch placement in a single round-trip and seed
    /// the cache for each, ahead of the per-placement warm pass.
    ///
    /// This is purely an optimization. When it succeeds, the subsequent
    /// `prefetch(...)` hits Tier 0 for every seeded placement (no per-placement
    /// network resolve). When it fails — the batch endpoint isn't deployed yet,
    /// the device is offline, the resolve errors — it is silently ignored and
    /// `prefetch(...)` falls back to per-placement resolves (each coalesced and
    /// cached as usual), so launch prefetch never regresses. Only engaged for 2+
    /// placements; a single one is cheaper to resolve directly. The fingerprint
    /// and `setFlow` key match exactly what the warm pass's Tier-0 lookup uses,
    /// so seeded entries are found.
    private func batchSeedCache(_ placementKeys: [String]) async {
        guard placementKeys.count > 1 else { return }
        let fingerprint = currentFingerprint()
        do {
            let byKey = try await resolveService.resolveBatch(
                placementIds: placementKeys,
                userId: SessionManager.shared.userId,
                sessionId: SessionManager.shared.sessionId,
                attributes: buildAttributes()
            )
            var seeded = 0
            for (key, response) in byKey {
                // Only seed presentable flows; a no-flow result is left for the
                // warm pass to classify (and a stale entry would just be skipped).
                guard response.hasFlow, let flow = try? ResolvedFlow(from: response) else { continue }
                do {
                    try flow.validateSchemaVersion()
                } catch {
                    continue
                }
                guard flow.validateForPresentation() else { continue }
                flowCache.setFlow(flow, placementId: key, fingerprint: fingerprint)
                seeded += 1
            }
            Logger.shared.debug("Launch prefetch: batch-seeded \(seeded)/\(placementKeys.count) placement(s) in one round-trip.")
        } catch {
            Logger.shared.debug("Launch prefetch: batch resolve unavailable (\(error)); falling back to per-placement resolves.")
        }
    }

    /// Warm a single placement through the cache-populating resolve path and
    /// report the outcome. Shared by `prefetch` and `isPlacementReady` so both
    /// leave the cache populated (no wasted resolves) and classify the result
    /// identically. Never throws.
    private func warm(placementKey: String, warmMedia: Bool) async -> PrefetchOutcome {
        do {
            let (flow, source) = try await resolveDelivery(placementKey)
            // Best-effort: warm media so the flow is visually instant on arrival,
            // not just structurally cached. Never fails the prefetch.
            let mediaWarmed = warmMedia ? await warmFlowMedia(for: flow) : false
            // `fromCache`: served from a local cached copy (fresh or last-known-good)
            // without a fresh network resolve, vs freshly resolved / bundled.
            let fromCache: Bool
            switch source {
            case .cache, .staleCache:
                fromCache = true
            case .network, .bundledDefault:
                fromCache = false
            }
            Logger.shared.debug("Warmed placement '\(placementKey)' from \(source.rawValue)")
            return PrefetchOutcome(
                placementKey: placementKey,
                state: .warmed(fromCache: fromCache),
                mediaWarmed: mediaWarmed
            )
        } catch let error as FlowPilotError {
            // A clean "no flow for this placement" is distinct from a failure:
            // the resolve worked, the backend just had nothing to show.
            if error.code == .flowNotFound {
                Logger.shared.debug("Prefetch: no flow for placement '\(placementKey)'")
                return PrefetchOutcome(placementKey: placementKey, state: .noFlow, mediaWarmed: false)
            }
            Logger.shared.warn("Failed to prefetch '\(placementKey)': \(error)")
            return PrefetchOutcome(placementKey: placementKey, state: .failed(error), mediaWarmed: false)
        } catch {
            Logger.shared.warn("Failed to prefetch '\(placementKey)': \(error)")
            return PrefetchOutcome(
                placementKey: placementKey,
                state: .failed(.networkError(error)),
                mediaWarmed: false
            )
        }
    }

    /// Resolve whether media should be warmed for a *manual* `prefetch(...)` call.
    ///
    /// An explicit `warmMedia` argument always wins. When `nil`, media is left
    /// un-warmed so existing `prefetch([...])` call sites keep their established
    /// JSON + fonts behavior — callers opt into media with `warmMedia: true`. The
    /// background launch prefetch derives its own flag from
    /// `prefetchMediaStrategy` (see `runLaunchPrefetch`); `prefetchMediaStrategy`
    /// still governs the *screen window* warmed once media warming is on (see
    /// `warmFlowMedia`).
    private func resolveWarmMedia(_ override: Bool?) -> Bool {
        return override ?? false
    }

    /// Warm a flow's images into `ImageCache` so it paints instantly on arrival.
    ///
    /// The screen window is bounded by `configuration.prefetchMediaStrategy`:
    /// `.allScreens` warms every screen's art, every other strategy bounds
    /// warming to the first screen + persistent zones so launch prefetch stays
    /// cheap. Best-effort: respects `MediaPreloader`'s concurrency cap and
    /// `hasImage` skip, never throws, and returns whether any image is now cached.
    private func warmFlowMedia(for flow: ResolvedFlow) async -> Bool {
        let store = makeTransientVariableStore(for: flow)
        let firstScreenOnly = configuration.prefetchMediaStrategy != .allScreens
        let result = await MediaPreloader().preloadFlow(
            flow,
            variableStore: store,
            firstScreenOnly: firstScreenOnly
        )
        return result.successfulItems > 0
    }

    /// Build a throwaway `VariableStore` so media URL resolution (conditional /
    /// interpolated `src`) matches what a real session would compute, without
    /// creating a full `FlowSession`. Mirrors `FlowSession.init`'s variable setup.
    private func makeTransientVariableStore(for flow: ResolvedFlow) -> VariableStore {
        let store = VariableStore()
        store.initialize(
            variables: flow.definition.variables ?? [],
            sdkContext: sdkContext
        )
        store.setThemeColors(flow.definition.globalStyles?.colors)
        return store
    }

    // MARK: - Conversion Tracking

    /// Track a purchase / paywall conversion.
    ///
    /// Routes the event through the most-recently-started flow session's
    /// analytics tracker, so the conversion is attributed to that flow's
    /// `flow_id`, `flow_version_id`, `placement_id`, `experiment_id`, and
    /// `variant_id`. Use this from purchase-completion callbacks (e.g. Apple
    /// IAP `paymentQueue(_:updatedTransactions:)`) which fire on a separate
    /// thread after the flow's `presentPlacement` call returns.
    ///
    /// If no flow session has been started yet, the event is dropped with a
    /// warning — the backend requires non-empty flow context. Make sure to
    /// call this only after a paywall / onboarding flow has been presented.
    ///
    /// Thread-safe — can be called from any thread.
    ///
    /// Example:
    /// ```swift
    /// FlowPilot.shared?.trackConversion(
    ///     amount: 9.99,
    ///     currency: "USD",
    ///     productId: "premium_yearly"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - amount: Purchase amount in `currency`'s decimal units (e.g. `9.99`).
    ///   - currency: ISO 4217 currency code (e.g. `"USD"`).
    ///   - productId: Optional product identifier (e.g. Apple IAP product ID).
    ///   - metadata: Optional additional properties to attach to the event.
    public func trackConversion(
        amount: Double,
        currency: String,
        productId: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        activeSessionLock.lock()
        let session = activeSession
        activeSessionLock.unlock()

        guard let session = session else {
            Logger.shared.warn("FlowPilot.trackConversion: no active flow session, conversion event dropped. Call this only after presenting a flow (presentPlacement or createSession).")
            return
        }

        session.trackConversion(
            amount: amount,
            currency: currency,
            productId: productId,
            metadata: metadata
        )
    }

    // MARK: - Identity

    /// Associate subsequent events with a stable, app-provided user id (e.g.
    /// your account id), persisted in the Keychain across launches. Without
    /// this, FlowPilot uses an anonymous per-install id — accurate for
    /// "returning installs" but never tied to a real account. Safe to call any
    /// time; a flow session already in progress keeps the id it started with.
    ///
    /// Mirrors the Expo SDK's `FlowPilot.identify(_:)`.
    ///
    /// ```swift
    /// FlowPilot.identify(currentUser.id)
    /// ```
    public static func identify(_ userId: String) {
        guard !userId.isEmpty else {
            Logger.shared.warn("FlowPilot.identify: empty userId ignored")
            return
        }
        SessionManager.shared.setUserId(userId)
    }

    /// Clear the current identity (e.g. on logout). A fresh anonymous id and a
    /// new session are created for subsequent activity. Mirrors the Expo SDK's
    /// `FlowPilot.reset()`.
    public static func reset() {
        SessionManager.shared.clearAll()
    }

    // MARK: - Cache Management

    /// Clear all cached flows and fonts
    public func clearCache() async {
        flowCache.clear()
        FontManager.shared.clearCache()
        IconCache.shared.clearAll()
        Logger.shared.info("Cache cleared")
    }

    // MARK: - Fallback & Resilience

    /// Register a build-time default flow for a placement from raw JSON data.
    ///
    /// Used as the offline fallback (Tier 3): when a live resolve fails and no
    /// cache is available, the SDK renders this flow so onboarding still works
    /// with no network and no prior cache. The JSON is the payload exported from
    /// the FlowPilot editor (a resolve response, or a bare flow definition).
    ///
    /// Pass `assets` to also ship the flow's images and fonts in the app bundle
    /// so it renders **fully offline** (no remote image / font requests).
    public func registerBundledFlow(placementKey: String, json: Data, assets: BundledFlowAssets? = nil) {
        bundledFlowProvider.register(placementKey: placementKey, json: json)
        if let assets { bundledFlowProvider.register(placementKey: placementKey, assets: assets) }
        Logger.shared.debug("Registered bundled flow (data) for placement: \(placementKey)\(assets != nil ? " + offline assets" : "")")
    }

    /// Register a build-time default flow for a placement from a bundle resource.
    ///
    /// Pass `assets` to also seed the flow's images and fonts from the app bundle
    /// so it renders fully offline.
    public func registerBundledFlow(
        placementKey: String,
        resource: String,
        withExtension ext: String = "json",
        in bundle: Bundle = .main,
        assets: BundledFlowAssets? = nil
    ) {
        bundledFlowProvider.registerResource(
            placementKey: placementKey,
            resource: resource,
            withExtension: ext,
            in: bundle
        )
        if let assets { bundledFlowProvider.register(placementKey: placementKey, assets: assets) }
        Logger.shared.debug("Registered bundled flow (resource '\(resource).\(ext)') for placement: \(placementKey)\(assets != nil ? " + offline assets" : "")")
    }

    /// Register a build-time default flow from an exported `.flowassets` folder
    /// reference — the all-in-one offline default.
    ///
    /// The folder is expected to contain `flow.json`, `manifest.json`, and the
    /// referenced `images/` and `fonts/` files (see the editor's "Export offline
    /// default" output). Drop the folder into your app target as a folder
    /// reference and pass its name as `assetBundle`.
    ///
    /// ```swift
    /// FlowPilot.shared?.registerBundledFlow(
    ///     placementKey: "onboarding",
    ///     assetBundle: "OnboardingDefault.flowassets"
    /// )
    /// ```
    public func registerBundledFlow(
        placementKey: String,
        assetBundle subdirectory: String,
        in bundle: Bundle = .main,
        flowResource: String = "flow",
        manifestResource: String = "manifest"
    ) {
        bundledFlowProvider.registerResource(
            placementKey: placementKey,
            resource: flowResource,
            withExtension: "json",
            subdirectory: subdirectory,
            in: bundle
        )
        bundledFlowProvider.register(
            placementKey: placementKey,
            assets: BundledFlowAssets(bundle: bundle, subdirectory: subdirectory, manifest: manifestResource)
        )
        Logger.shared.debug("Registered bundled flow + offline assets (assetBundle '\(subdirectory)') for placement: \(placementKey)")
    }

    /// Register only the offline image/font assets for a placement whose bundled
    /// flow JSON was registered separately. Useful when the flow and its assets
    /// are declared in different places.
    public func registerBundledFlowAssets(placementKey: String, assets: BundledFlowAssets) {
        bundledFlowProvider.register(placementKey: placementKey, assets: assets)
        Logger.shared.debug("Registered offline assets for placement: \(placementKey)")
    }

    // MARK: - Custom Component Registration

    /// Register a custom component with key and version
    ///
    /// The SDK registers components by **key + version** to support schema evolution.
    /// When looking up components, the SDK will match against the exact version specified
    /// in the flow JSON.
    ///
    /// - Parameters:
    ///   - key: Component key (e.g., "my_paywall", "test_3")
    ///   - version: Component version (defaults to 1)
    ///   - definition: Component definition with inputs, outputs, and factory
    ///
    /// Example:
    /// ```swift
    /// FlowPilot.shared?.registerCustomComponent(
    ///     key: "test_3",
    ///     version: 1,
    ///     definition: CustomComponentDefinition(...)
    /// )
    /// ```
    public func registerCustomComponent(
        key: String,
        version: Int = 1,
        definition: CustomComponentDefinition
    ) {
        registryLock.lock()
        defer { registryLock.unlock() }

        let registryKey = "\(key)_v\(version)"
        customComponents[registryKey] = definition

        // Also register without version for backward compatibility (if version is 1)
        if version == 1 {
            customComponents[key] = definition
        }

        Logger.shared.debug("Registered custom component: \(key) (v\(version))")
    }

    /// Register a custom component (legacy API - uses version 1)
    @available(*, deprecated, message: "Use registerCustomComponent(key:version:definition:) instead")
    public func registerCustomComponent(_ typeId: String, definition: CustomComponentDefinition) {
        registerCustomComponent(key: typeId, version: 1, definition: definition)
    }

    /// Unregister a custom component
    public func unregisterCustomComponent(key: String, version: Int = 1) {
        registryLock.lock()
        defer { registryLock.unlock() }

        let registryKey = "\(key)_v\(version)"
        customComponents.removeValue(forKey: registryKey)

        // Also remove the non-versioned key if version is 1
        if version == 1 {
            customComponents.removeValue(forKey: key)
        }

        Logger.shared.debug("Unregistered custom component: \(key) (v\(version))")
    }

    /// Unregister a custom component (legacy API)
    @available(*, deprecated, message: "Use unregisterCustomComponent(key:version:) instead")
    public func unregisterCustomComponent(_ typeId: String) {
        unregisterCustomComponent(key: typeId, version: 1)
    }

    /// Look up a custom component by key and version
    /// Returns nil if not found (caller should show placeholder)
    internal func getCustomComponent(key: String, version: Int) -> CustomComponentDefinition? {
        registryLock.lock()
        defer { registryLock.unlock() }

        // Try versioned key first
        let registryKey = "\(key)_v\(version)"
        if let definition = customComponents[registryKey] {
            return definition
        }

        // Fall back to non-versioned key (for backward compatibility)
        return customComponents[key]
    }

    // MARK: - Custom Screen Registration

    /// Register a custom screen
    public func registerCustomScreen(_ screenId: String, definition: CustomScreenDefinition) {
        registryLock.lock()
        defer { registryLock.unlock() }

        customScreens[screenId] = definition
        Logger.shared.debug("Registered custom screen: \(screenId)")
    }

    /// Unregister a custom screen
    public func unregisterCustomScreen(_ screenId: String) {
        registryLock.lock()
        defer { registryLock.unlock() }

        customScreens.removeValue(forKey: screenId)
        Logger.shared.debug("Unregistered custom screen: \(screenId)")
    }

    // MARK: - Debug

    /// Whether debug borders are shown on rendered components
    public static var debugBordersEnabled: Bool = false

    /// Enable debug overlay (development only)
    public func enableDebugOverlay() {
        Logger.shared.setLogLevel(.verbose)
        Logger.shared.info("Debug overlay enabled")
    }

    /// Disable debug overlay
    public func disableDebugOverlay() {
        Logger.shared.setLogLevel(configuration.logLevel)
    }

    /// Log current SDK state
    public func logState() {
        Logger.shared.info("=== FlowPilot State ===")
        Logger.shared.info("User ID: \(SessionManager.shared.userId)")
        Logger.shared.info("Session ID: \(SessionManager.shared.sessionId)")
        Logger.shared.info("Environment: \(configuration.environment.name)")
        Logger.shared.info("Custom Components: \(customComponents.count)")
        Logger.shared.info("Custom Screens: \(customScreens.count)")
        Logger.shared.info("=======================")
    }

    // MARK: - Helpers

    /// The identity-aware cache fingerprint for the *current* user + attributes.
    ///
    /// Mirrors exactly the inputs `performNetworkResolve` sends to the backend
    /// (`SessionManager.shared.userId` + `buildAttributes()`), so the cache key a
    /// flow is stored under matches the identity it was resolved for. `sessionId`
    /// is intentionally not included (see `ResolveFingerprint`).
    private func currentFingerprint() -> String {
        return ResolveFingerprint.make(
            userId: SessionManager.shared.userId,
            attributes: buildAttributes()
        )
    }

    private func buildAttributes() -> [String: Any] {
        var attributes: [String: Any] = [:]

        // Add SDK context as attributes
        for (key, value) in sdkContext {
            attributes[key] = value
        }

        // Add device info
        attributes["device.platform"] = "ios"
        attributes["device.os_version"] = ProcessInfo.processInfo.operatingSystemVersionString

        #if canImport(UIKit)
        attributes["device.model"] = UIDevice.current.model
        #endif

        // Add app info
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            attributes["app.version"] = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            attributes["app.build"] = build
        }

        return attributes
    }
}

// MARK: - SwiftUI Convenience

extension FlowPilot {
    /// Create a flow session for SwiftUI presentation
    @MainActor
    public func createSession(
        placementKey: String,
        additionalContext: SDKContext? = nil,
        preloadMedia: Bool? = nil
    ) async throws -> FlowSession {
        let (flow, deliverySource) = try await resolveDelivery(placementKey)

        var mergedContext = sdkContext
        if let additional = additionalContext {
            for (key, value) in additional {
                mergedContext[key] = value
            }
        }

        let session = FlowSession(
            flow: flow,
            placementId: placementKey,
            sdkContext: mergedContext,
            eventService: eventService,
            analyticsCallback: analyticsCallback,
            preloadMedia: preloadMedia ?? configuration.mediaPreloadingEnabled,
            deliverySource: deliverySource
        )
        setActiveSession(session)
        return session
    }

    /// Non-throwing SwiftUI counterpart to `createSession`. Walks the full
    /// fallback chain (fresh cache → live resolve with hard timeout → stale
    /// cache → bundled default) and returns a ready `FlowSession`, or `nil` when
    /// FlowPilot has nothing presentable — at which point the host should render
    /// its own native onboarding. Never throws, never crashes.
    ///
    /// ```swift
    /// if let session = await FlowPilot.shared?.resolveSession(placementKey: "onboarding") {
    ///     FlowPresenterView(session: session)
    /// } else {
    ///     MyNativeOnboardingView()
    /// }
    /// ```
    @MainActor
    public func resolveSession(
        placementKey: String,
        additionalContext: SDKContext? = nil,
        preloadMedia: Bool? = nil
    ) async -> FlowSession? {
        do {
            return try await createSession(
                placementKey: placementKey,
                additionalContext: additionalContext,
                preloadMedia: preloadMedia
            )
        } catch {
            Logger.shared.warn("resolveSession: no FlowPilot flow available for '\(placementKey)' (\(error)). Host should show its own fallback.")
            return nil
        }
    }

    /// Clear all cached images and icons
    public func clearImageCache() {
        ImageCache.shared.clearAll()
        IconCache.shared.clearAll()
        Logger.shared.info("Image and icon cache cleared")
    }

    /// Get the shared image cache for advanced usage
    public var imageCache: ImageCache {
        return ImageCache.shared
    }
}

// MARK: - Debug / Testing

#if DEBUG
extension FlowPilot {
    /// Test-only: run the full delivery chain exactly as presentation does and
    /// report which tier served the flow. Lets tests assert that a prior
    /// `prefetch` / `isPlacementReady` left the cache warm — i.e. a subsequent
    /// "present" hits Tier 0 (`.cache`) without another network resolve.
    func resolveDeliverySourceForTesting(_ placementKey: String) async throws -> FlowDeliverySource {
        try await resolveDelivery(placementKey).source
    }

    /// Create a test session with dummy flow data for debugging rendering
    @MainActor
    public func createTestSession() -> FlowSession {
        let dummyFlow = ResolvedFlow.createDummyFlow()
        return FlowSession(
            flow: dummyFlow,
            placementId: "test",
            sdkContext: sdkContext,
            eventService: eventService,
            analyticsCallback: analyticsCallback,
            preloadMedia: false // No preloading for test sessions
        )
    }
}

extension ResolvedFlow {
    /// Create a dummy flow for testing rendering
    static func createDummyFlow() -> ResolvedFlow {
        // Create a simple screen with text and button
        let textNode = ComponentNode.createText(
            id: "text_1",
            text: "Welcome to FlowPilot!",
            fontSize: 24,
            fontWeight: "bold",
            color: "#000000"
        )

        let subtitleNode = ComponentNode.createText(
            id: "text_2",
            text: "This is a test screen to verify rendering works correctly.",
            fontSize: 16,
            color: "#666666"
        )

        let buttonNode = ComponentNode.createButton(
            id: "button_1",
            text: "Continue",
            backgroundColor: "#007AFF",
            textColor: "#FFFFFF",
            action: .closeFlow
        )

        let stackNode = ComponentNode.createStack(
            id: "stack_1",
            axis: "vertical",
            spacing: 20,
            children: [textNode, subtitleNode, buttonNode]
        )

        let screenNode = ScreenNode(
            id: "screen_1",
            kind: "screen",
            name: "Test Screen",
            screenType: .standard,
            props: ScreenProps.createDefault(),
            layout: stackNode,
            customScreen: nil
        )

        let flowDefinition = FlowDefinition.createDummy(
            id: "test_flow",
            name: "Test Flow",
            entryNodeId: "screen_1",
            nodes: [.screen(screenNode)],
            edges: []
        )

        return ResolvedFlow(
            flowId: "test_flow",
            flowVersionId: "test_v1",
            flowVersion: 1,
            schemaVersion: "1.0.0",
            definition: flowDefinition,
            mediaBaseUrl: nil,
            iconBaseUrl: nil,
            fonts: nil,
            experimentId: nil,
            variantId: nil,
            variantName: nil,
            cacheTtlSeconds: 0,
            resolvedAt: Date()
        )
    }

    // Internal initializer for testing
    init(
        flowId: String,
        flowVersionId: String,
        flowVersion: Int,
        schemaVersion: String,
        definition: FlowDefinition,
        mediaBaseUrl: String?,
        iconBaseUrl: String? = nil,
        fonts: [FontFile]? = nil,
        experimentId: String?,
        variantId: String?,
        variantName: String?,
        cacheTtlSeconds: Int,
        resolvedAt: Date
    ) {
        self.flowId = flowId
        self.flowVersionId = flowVersionId
        self.flowVersion = flowVersion
        self.schemaVersion = schemaVersion
        self.definition = definition
        self.mediaBaseUrl = mediaBaseUrl
        self._iconBaseUrl = iconBaseUrl
        self.fonts = fonts
        self.experimentId = experimentId
        self.variantId = variantId
        self.variantName = variantName
        self.cacheTtlSeconds = cacheTtlSeconds
        self.resolvedAt = resolvedAt
    }
}

// MARK: - Test Helpers for ComponentNode

extension ComponentNode {
    static func createText(
        id: String,
        text: String,
        fontSize: Double = 16,
        fontWeight: String = "regular",
        color: String = "#000000"
    ) -> ComponentNode {
        let propsDict: [String: Any] = [
            "text": text,
            "fontSize": fontSize,
            "fontWeight": fontWeight,
            "color": color
        ]
        return ComponentNode(
            id: id,
            type: .text,
            props: ComponentProps.fromDict(propsDict),
            children: nil,
            interactions: nil
        )
    }

    static func createButton(
        id: String,
        text: String,
        backgroundColor: String = "#007AFF",
        textColor: String = "#FFFFFF",
        action: ComponentAction
    ) -> ComponentNode {
        let propsDict: [String: Any] = [
            "text": text,
            "backgroundColor": backgroundColor,
            "color": textColor,
            "paddingVertical": 16,
            "paddingHorizontal": 32,
            "cornerRadius": 12
        ]
        let interaction = ComponentInteraction(
            id: "\(id)_tap",
            event: .onPress,
            actions: [action]
        )
        return ComponentNode(
            id: id,
            type: .button,
            props: ComponentProps.fromDict(propsDict),
            children: nil,
            interactions: [interaction]
        )
    }

    static func createStack(
        id: String,
        axis: String = "vertical",
        spacing: Double = 8,
        children: [ComponentNode]
    ) -> ComponentNode {
        let propsDict: [String: Any] = [
            "axis": axis,
            "spacing": spacing,
            "paddingVertical": 24,
            "paddingHorizontal": 16
        ]
        return ComponentNode(
            id: id,
            type: .stack,
            props: ComponentProps.fromDict(propsDict),
            children: children,
            interactions: nil
        )
    }
}

extension ComponentProps {
    static func fromDict(_ dict: [String: Any]) -> ComponentProps {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(ComponentProps.self, from: data)
    }
}

extension ScreenProps {
    static func createDefault() -> ScreenProps {
        let data = try! JSONSerialization.data(withJSONObject: ["backgroundColor": "#FFFFFF"])
        return try! JSONDecoder().decode(ScreenProps.self, from: data)
    }
}

extension FlowDefinition {
    static func createDummy(
        id: String,
        name: String,
        entryNodeId: String,
        nodes: [FlowNode],
        edges: [FlowEdge]
    ) -> FlowDefinition {
        let dict: [String: Any] = [
            "id": id,
            "name": name,
            "version": 1,
            "schemaVersion": "1.0.0",
            "entryNodeId": entryNodeId,
            "nodes": nodes.map { nodeToDict($0) },
            "edges": edges.map { edgeToDict($0) }
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(FlowDefinition.self, from: data)
    }

    private static func nodeToDict(_ node: FlowNode) -> [String: Any] {
        switch node {
        case .screen(let screen):
            var dict: [String: Any] = [
                "id": screen.id,
                "kind": "screen",
                "name": screen.name
            ]
            if let layout = screen.layout {
                dict["layout"] = componentToDict(layout)
            }
            return dict
        default:
            return ["id": node.id, "kind": node.kind]
        }
    }

    private static func componentToDict(_ node: ComponentNode) -> [String: Any] {
        var dict: [String: Any] = [
            "id": node.id,
            "type": node.type.rawValue
        ]
        if let props = node.props {
            // Re-encode props
            let data = try! JSONEncoder().encode(props)
            dict["props"] = try! JSONSerialization.jsonObject(with: data)
        }
        if let children = node.children {
            dict["children"] = children.map { componentToDict($0) }
        }
        if let interactions = node.interactions {
            dict["interactions"] = interactions.map { interactionToDict($0) }
        }
        return dict
    }

    private static func interactionToDict(_ interaction: ComponentInteraction) -> [String: Any] {
        return [
            "id": interaction.id,
            "event": interaction.event.rawValue,
            "actions": interaction.actions.map { scheduled -> [String: Any] in
                // Keep the wire shape flat: `delay` sits alongside the action's
                // own keys, mirroring how it decodes.
                var dict = actionToDict(scheduled.action)
                if let delay = scheduled.delay {
                    dict["delay"] = delay
                }
                return dict
            }
        ]
    }

    private static func actionToDict(_ action: ComponentAction) -> [String: Any] {
        switch action {
        case .closeFlow:
            return ["kind": "closeFlow"]
        case .navigate(let targetNodeId):
            return ["kind": "navigate", "targetNodeId": targetNodeId]
        case .goBack:
            return ["kind": "goBack"]
        default:
            return ["kind": action.kind]
        }
    }

    private static func edgeToDict(_ edge: FlowEdge) -> [String: Any] {
        return [
            "id": edge.id,
            "fromNodeId": edge.fromNodeId,
            "toNodeId": edge.toNodeId
        ]
    }
}

#endif

// MARK: - FlowPilot Delegate

/// Delegate protocol for FlowPilot callbacks
public protocol FlowPilotDelegate: AnyObject {
    /// Called when a flow completes successfully
    func flowPilotDidComplete(_ flowId: String, result: FlowResult)

    /// Called when a flow is dismissed
    func flowPilotDidDismiss(_ flowId: String)

    /// Called when an error occurs
    func flowPilotDidFail(_ error: FlowPilotError)
}

// Optional default implementations
extension FlowPilotDelegate {
    public func flowPilotDidComplete(_ flowId: String, result: FlowResult) {}
    public func flowPilotDidDismiss(_ flowId: String) {}
    public func flowPilotDidFail(_ error: FlowPilotError) {}
}
