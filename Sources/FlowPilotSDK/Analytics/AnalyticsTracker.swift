import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Analytics Tracker

/// Tracks analytics events for flows
final class AnalyticsTracker: @unchecked Sendable {
    // Flow context
    private var appId: String = ""
    private var placementId: String?
    private var flowId: String = ""
    private var flowVersionId: String = ""
    private var flowVersion: Int = 0
    private var experimentId: String?
    private var variantId: String?
    private var variantName: String?
    private var deliverySource: FlowDeliverySource = .network

    /// Cumulative in-flow A/B attribution for this session (abTest node id →
    /// chosen variant id). Stamped onto EVERY event as `ab_assignments`. Reset
    /// per flow/session in `configure`, appended on each in-flow bucketing, and
    /// reseeded from the progress snapshot on a resumed session. Distinct from
    /// the server-side `experimentId`/`variantId` columns above.
    private var abAssignments: [String: String] = [:]

    // Timing
    private var flowStartTime: Date?
    private var screenStartTime: Date?
    private var currentScreenId: String?
    private var currentScreenName: String?
    private var currentScreenIndex: Int = 0
    private var screensViewed: [String] = []

    // Event batching
    private let batcher: AnalyticsBatcher
    private let eventService: EventService?

    // External callback
    private var externalCallback: AnalyticsCallback?

    // Lock for thread safety
    private let lock = NSLock()

    // MARK: - Initialization

    init(eventService: EventService?, externalCallback: AnalyticsCallback? = nil) {
        self.eventService = eventService
        self.externalCallback = externalCallback
        self.batcher = AnalyticsBatcher(eventService: eventService)

        setupAppLifecycleObservers()
    }

    deinit {
        #if canImport(UIKit)
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    // MARK: - Configuration

    func configure(
        appId: String,
        placementId: String?,
        flowId: String,
        flowVersionId: String,
        flowVersion: Int,
        experimentId: String?,
        variantId: String?,
        variantName: String?,
        deliverySource: FlowDeliverySource = .network
    ) {
        lock.lock()
        defer { lock.unlock() }

        self.appId = appId
        self.placementId = placementId
        self.flowId = flowId
        self.flowVersionId = flowVersionId
        self.flowVersion = flowVersion
        self.experimentId = experimentId
        self.variantId = variantId
        self.variantName = variantName
        self.deliverySource = deliverySource
        // New flow/session: start with no in-flow A/B attribution. A resumed
        // session reseeds this via restoreAbAssignments after restore.
        self.abAssignments = [:]
    }

    /// Reseed the cumulative in-flow A/B attribution map (e.g. after restoring
    /// saved progress) so events emitted post-resume still carry `ab_assignments`.
    func restoreAbAssignments(_ assignments: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        self.abAssignments = assignments
    }

    func setExternalCallback(_ callback: AnalyticsCallback?) {
        lock.lock()
        defer { lock.unlock() }
        self.externalCallback = callback
    }

    // MARK: - Automatic Events

    func trackFlowStarted() {
        lock.lock()
        flowStartTime = Date()
        screensViewed = []
        lock.unlock()

        let event = buildEvent(eventType: .flowStarted)
            .withProperties([
                "flow_name": flowId,
                "entry_node_id": currentScreenId ?? ""
            ])
            .build()

        enqueue(event)
    }

    func trackScreenViewed(screenId: String, screenName: String, screenIndex: Int) {
        lock.lock()

        // Capture the previous screen so we can emit screen_exit for it. The
        // exit event carries time_on_screen_ms, which is what time-per-screen
        // aggregations read on the backend.
        let previousScreenId = currentScreenId
        let previousScreenName = currentScreenName
        let previousScreenIndex = currentScreenIndex
        let previousScreenStartTime = screenStartTime

        currentScreenId = screenId
        currentScreenName = screenName
        currentScreenIndex = screenIndex
        screenStartTime = Date()

        if !screensViewed.contains(screenId) {
            screensViewed.append(screenId)
        }

        lock.unlock()

        // Emit screen_exit for the previous screen (if any). Guard against the
        // degenerate same-screen case so a re-emitted screen_view doesn't
        // produce a phantom exit for the screen the user is still on.
        if let previousScreenId, previousScreenId != screenId {
            let timeOnPreviousScreen = previousScreenStartTime.map { Int(Date().timeIntervalSince($0) * 1000) }
            let exitEvent = buildEvent(eventType: .screenExited)
                .withScreen(
                    screenId: previousScreenId,
                    screenName: previousScreenName,
                    screenIndex: previousScreenIndex
                )
                .withTiming(
                    timeSinceFlowStartMs: timeSinceFlowStart(),
                    timeOnScreenMs: timeOnPreviousScreen
                )
                .build()
            enqueue(exitEvent)
        }

        // screen_view is the entry event; time_on_screen_ms stays nil here and
        // is populated by the matching screen_exit emitted on the next
        // transition or on flow close.
        let event = buildEvent(eventType: .screenViewed)
            .withScreen(screenId: screenId, screenName: screenName, screenIndex: screenIndex)
            .withTiming(
                timeSinceFlowStartMs: timeSinceFlowStart(),
                timeOnScreenMs: nil
            )
            .build()

        enqueue(event)
    }

    /// Emits screen_exit for the current screen, if any. Clears the screen
    /// state so subsequent calls (e.g. multiple flow-close paths) do not
    /// double-emit. Safe to call when no screen is active — no-op in that case.
    func trackScreenExited() {
        lock.lock()
        guard let screenId = currentScreenId else {
            lock.unlock()
            return
        }
        let screenName = currentScreenName
        let screenIndex = currentScreenIndex
        let startTime = screenStartTime

        // Clear screen state before emitting so a concurrent caller racing on
        // the lock cannot also produce an exit for the same screen.
        currentScreenId = nil
        currentScreenName = nil
        screenStartTime = nil
        lock.unlock()

        let timeOnScreen = startTime.map { Int(Date().timeIntervalSince($0) * 1000) }
        let event = buildEvent(eventType: .screenExited)
            .withScreen(screenId: screenId, screenName: screenName, screenIndex: screenIndex)
            .withTiming(
                timeSinceFlowStartMs: timeSinceFlowStart(),
                timeOnScreenMs: timeOnScreen
            )
            .build()

        enqueue(event)
    }

    func trackFlowCompleted() {
        let event = buildEvent(eventType: .flowCompleted)
            .withTiming(timeSinceFlowStartMs: timeSinceFlowStart(), timeOnScreenMs: nil)
            .withProperties([
                "screens_viewed": screensViewed.count,
                "final_screen_id": currentScreenId ?? ""
            ])
            .build()

        enqueue(event)
        flush()
    }

    /// Emits a flow_exit event tagged with the screen the user was on at
    /// dismissal time. Pass the screen explicitly because the typical
    /// caller (`FlowSession.handleFlowClose`) emits `trackScreenExited()`
    /// first to land the dwell-time event — and that call clears the
    /// tracker's internal `currentScreen*` state. Without an explicit
    /// argument the dismiss event would ship with `screen_id = null`,
    /// breaking the per-screen drop-off math in the dashboard funnel.
    func trackFlowDismissed(
        screenId: String? = nil,
        screenName: String? = nil,
        screenIndex: Int? = nil
    ) {
        let resolvedScreenId = screenId ?? currentScreenId
        let resolvedScreenName = screenName ?? currentScreenName
        let resolvedScreenIndex = screenIndex ?? currentScreenIndex

        let event = buildEvent(eventType: .flowDismissed)
            .withScreen(
                screenId: resolvedScreenId,
                screenName: resolvedScreenName,
                screenIndex: resolvedScreenIndex
            )
            .withTiming(timeSinceFlowStartMs: timeSinceFlowStart(), timeOnScreenMs: nil)
            .withProperties([
                "screens_viewed": screensViewed.count
            ])
            .build()

        enqueue(event)
        flush()
    }

    /// Server-side experiment exposure (resolver-assigned variant). Stamps the
    /// real top-level `experiment_id`/`variant_id` columns — those stay reserved
    /// for server-side experiments. Unchanged: the in-flow path uses
    /// `trackInFlowExperimentAssigned` and `ab_assignments` instead.
    func trackExperimentAssigned(experimentKey: String, variantId: String, variantLabel: String?) {
        let event = buildEvent(eventType: .experimentAssigned)
            .withExperiment(experimentId: experimentKey, variantId: variantId, variantName: variantLabel)
            .withProperties([
                "experiment_key": experimentKey
            ])
            .build()

        enqueue(event)
    }

    /// In-flow A/B exposure (client-side bucketing at an abTest node). Records
    /// the node→variant choice into `abAssignments` BEFORE building the event so
    /// the exposure itself (and every subsequent event) carries it via
    /// `ab_assignments`. Deliberately does NOT overwrite the top-level
    /// `experiment_id`/`variant_id` columns — in-flow attribution lives only in
    /// `ab_assignments`. Fired once per session per node by the navigation layer.
    func trackInFlowExperimentAssigned(
        nodeId: String,
        experimentKey: String,
        variantId: String,
        variantLabel: String?
    ) {
        lock.lock()
        abAssignments[nodeId] = variantId
        lock.unlock()

        let event = buildEvent(eventType: .experimentAssigned)
            .withProperties([
                "experiment_key": experimentKey
            ])
            .build()

        enqueue(event)
    }

    func trackElementInteraction(
        elementId: String,
        elementType: String,
        interactionType: String = "tap"
    ) {
        let event = buildEvent(eventType: .elementInteraction)
            .withScreen(screenId: currentScreenId, screenName: currentScreenName, screenIndex: currentScreenIndex)
            .withElement(elementId: elementId, elementType: elementType, interactionType: interactionType)
            .withTiming(timeSinceFlowStartMs: timeSinceFlowStart(), timeOnScreenMs: nil)
            .build()

        enqueue(event)
    }

    // MARK: - Custom Events

    func trackCustomEvent(
        eventKey: String,
        properties: [String: Any]?,
        elementId: String? = nil,
        elementType: String? = nil
    ) {
        let event = AnalyticsEventBuilder(appId: appId, eventName: eventKey)
            .withPlacementId(placementId)
            .withFlowContext(flowId: flowId, flowVersionId: flowVersionId, flowVersion: flowVersion)
            .withExperiment(experimentId: experimentId, variantId: variantId, variantName: variantName)
            .withScreen(screenId: currentScreenId, screenName: currentScreenName, screenIndex: currentScreenIndex)
            .withElement(elementId: elementId, elementType: elementType, interactionType: nil)
            .withTiming(timeSinceFlowStartMs: timeSinceFlowStart(), timeOnScreenMs: nil)
            .withProperties(properties)
            .build()

        enqueue(event)
    }

    /// Track a purchase / paywall conversion.
    ///
    /// - Parameters:
    ///   - revenue: Purchase amount in the smallest decimal unit of `currency`
    ///     (e.g. `9.99`). Pass `0` for non-monetary conversions (signups, etc.).
    ///   - currency: ISO 4217 currency code (e.g. `"USD"`). Normalised to
    ///     uppercase before being sent so downstream rollups don't fork on case.
    ///   - productId: Optional product identifier (e.g. an Apple IAP product
    ///     ID). Merged into `properties` under the `product_id` key so it
    ///     lands in ClickHouse's flexible properties column.
    ///   - metadata: Optional dictionary of additional properties to attach.
    ///     Reserved keys (`product_id`) set in metadata take precedence over
    ///     the dedicated `productId` parameter if both are supplied — the
    ///     dedicated parameter is the convenience, metadata is the escape
    ///     hatch.
    func trackConversion(
        revenue: Double,
        currency: String,
        productId: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        // Merge metadata + productId into a single properties dict. metadata
        // wins on key collision: callers who set product_id explicitly via
        // metadata expect that value to land in ClickHouse.
        var properties: [String: Any] = [:]
        if let productId = productId {
            properties["product_id"] = productId
        }
        if let metadata = metadata {
            for (key, value) in metadata {
                properties[key] = value
            }
        }

        let event = buildEvent(eventName: "conversion")
            .withRevenue(revenue, currency: currency.uppercased())
            .withTiming(timeSinceFlowStartMs: timeSinceFlowStart(), timeOnScreenMs: nil)
            .withProperties(properties.isEmpty ? nil : properties)
            .build()

        enqueue(event)
    }

    // MARK: - Batching

    func flush() {
        Task {
            await batcher.flush()
        }
    }

    private func enqueue(_ event: AnalyticsEvent) {
        // Stamp the cumulative in-flow A/B attribution onto EVERY event. This is
        // the single choke point all events flow through (auto, conversion,
        // custom), so every one carries the accumulated map. Omitted (nil) until
        // an abTest node has bucketed, so e.g. flow_start doesn't carry it.
        var event = event
        lock.lock()
        let assignments = abAssignments
        let callback = externalCallback
        lock.unlock()
        event.abAssignments = assignments.isEmpty ? nil : assignments

        // Send to batcher
        batcher.enqueue(event)

        // Also send to external callback
        callback?(event)
    }

    // MARK: - Helpers

    private func buildEvent(eventType: AutomaticEventType) -> AnalyticsEventBuilder {
        buildEvent(eventName: eventType.rawValue)
    }

    private func buildEvent(eventName: String) -> AnalyticsEventBuilder {
        return AnalyticsEventBuilder(appId: appId, eventName: eventName)
            .withPlacementId(placementId)
            .withFlowContext(flowId: flowId, flowVersionId: flowVersionId, flowVersion: flowVersion)
            .withExperiment(experimentId: experimentId, variantId: variantId, variantName: variantName)
            .withProperties(["delivery_source": deliverySource.rawValue])
    }

    private func timeSinceFlowStart() -> Int? {
        lock.lock()
        defer { lock.unlock() }

        guard let startTime = flowStartTime else { return nil }
        return Int(Date().timeIntervalSince(startTime) * 1000)
    }

    // MARK: - App Lifecycle

    private func setupAppLifecycleObservers() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }

    @objc private func appDidEnterBackground() {
        Logger.shared.debug("App backgrounded, flushing analytics")
        flush()
    }

    @objc private func appWillTerminate() {
        Logger.shared.debug("App terminating, flushing analytics")
        flush()
    }
}

// MARK: - Lock Extension

extension NSLock {
    func sync<T>(_ block: () -> T) -> T {
        lock()
        defer { unlock() }
        return block()
    }
}
