import Foundation

// MARK: - Analytics Event

/// Analytics event for FlowPilot tracking
public struct AnalyticsEvent: Codable, Sendable {
    // MARK: Required Fields

    /// Unique event identifier (generated client-side)
    public let eventId: String

    /// App ID
    public let appId: String

    /// Event name
    public let eventName: String

    /// Event timestamp (ISO 8601)
    public let timestamp: Date

    /// Placement ID that triggered the flow
    public let placementId: String?

    /// Flow ID
    public let flowId: String

    /// Flow version ID
    public let flowVersionId: String

    /// User ID
    public let userId: String

    /// Session ID
    public let sessionId: String

    /// Device platform
    public let devicePlatform: String

    /// SDK version
    public let sdkVersion: String

    /// True when emitted from a DEBUG build (Xcode run / simulator). The
    /// dashboard excludes debug traffic from production analytics so testing
    /// never inflates real user / impression counts.
    public let isDebug: Bool

    // MARK: Optional Fields

    /// Flow version number
    public let flowVersion: Int?

    /// Experiment ID (if in A/B test)
    public let experimentId: String?

    /// Variant ID (if in A/B test)
    public let variantId: String?

    /// Variant name (if in A/B test)
    public let variantName: String?

    /// Current screen ID
    public let screenId: String?

    /// Current screen name
    public let screenName: String?

    /// 0-indexed screen position
    public let screenIndex: Int?

    /// Interacted element ID
    public let elementId: String?

    /// Element type (button, toggle, etc.)
    public let elementType: String?

    /// Interaction type (tap, swipe, etc.)
    public let interactionType: String?

    /// Purchase amount (for conversions)
    public let revenue: Double?

    /// ISO 4217 currency code
    public let currency: String?

    /// Milliseconds since flow_start
    public let timeSinceFlowStartMs: Int?

    /// Time spent on current screen
    public let timeOnScreenMs: Int?

    /// Host app version
    public let appVersion: String?

    /// ISO 3166-1 alpha-2 country code
    public let country: String?

    /// Custom properties
    public let properties: [String: AnyCodable]?

    /// Cumulative in-flow A/B test assignments for this session: a map of
    /// abTest NODE id → chosen variant id. Stamped onto every event once any
    /// in-flow abTest node has bucketed, so per-variant funnels are possible.
    /// Omitted (nil) before any abTest node is hit and distinct from the
    /// top-level `experiment_id`/`variant_id` columns, which stay reserved for
    /// server-side experiments. Encoded as the JSON object `ab_assignments`;
    /// `var` so the tracker can stamp it after the event is built.
    public var abAssignments: [String: String]? = nil

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case appId = "app_id"
        case eventName = "event_type"
        case timestamp
        case placementId = "placement_id"
        case flowId = "flow_id"
        case flowVersionId = "flow_version_id"
        case userId = "user_id"
        case sessionId = "session_id"
        case devicePlatform = "device_platform"
        case sdkVersion = "sdk_version"
        case isDebug = "is_debug"
        case flowVersion = "flow_version"
        case experimentId = "experiment_id"
        case variantId = "variant_id"
        case variantName = "variant_name"
        case screenId = "screen_id"
        case screenName = "screen_name"
        case screenIndex = "screen_index"
        case elementId = "element_id"
        case elementType = "element_type"
        case interactionType = "interaction_type"
        case revenue
        case currency
        case timeSinceFlowStartMs = "time_since_flow_start_ms"
        case timeOnScreenMs = "time_on_screen_ms"
        case appVersion = "app_version"
        case country
        case properties
        case abAssignments = "ab_assignments"
    }

    // MARK: Initialization

    public init(
        appId: String,
        eventName: String,
        placementId: String?,
        flowId: String,
        flowVersionId: String,
        userId: String,
        sessionId: String,
        flowVersion: Int? = nil,
        experimentId: String? = nil,
        variantId: String? = nil,
        variantName: String? = nil,
        screenId: String? = nil,
        screenName: String? = nil,
        screenIndex: Int? = nil,
        elementId: String? = nil,
        elementType: String? = nil,
        interactionType: String? = nil,
        revenue: Double? = nil,
        currency: String? = nil,
        timeSinceFlowStartMs: Int? = nil,
        timeOnScreenMs: Int? = nil,
        properties: [String: Any]? = nil
    ) {
        // Swift's UUID().uuidString is uppercase; the backend's go-playground
        // validator `uuid` tag only matches lowercase, so uppercase UUIDs were
        // being silently rejected per-event with no useful client-side signal.
        self.eventId = UUID().uuidString.lowercased()
        self.appId = appId
        self.eventName = eventName
        self.timestamp = Date()
        self.placementId = placementId
        self.flowId = flowId
        self.flowVersionId = flowVersionId
        self.userId = userId
        self.sessionId = sessionId
        self.devicePlatform = "ios"
        self.sdkVersion = FlowPilotSDK.version
        #if DEBUG
        self.isDebug = true
        #else
        self.isDebug = false
        #endif
        self.flowVersion = flowVersion
        self.experimentId = experimentId
        self.variantId = variantId
        self.variantName = variantName
        self.screenId = screenId
        self.screenName = screenName
        self.screenIndex = screenIndex
        self.elementId = elementId
        self.elementType = elementType
        self.interactionType = interactionType
        self.revenue = revenue
        self.currency = currency
        self.timeSinceFlowStartMs = timeSinceFlowStartMs
        self.timeOnScreenMs = timeOnScreenMs
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if #available(iOS 16, macOS 13, *) {
            self.country = Locale.current.region?.identifier
        } else {
            self.country = Locale.current.regionCode
        }
        self.properties = properties?.mapValues { AnyCodable($0) }
    }
}

// MARK: - Automatic Event Types

/// Automatic event types that the SDK fires
public enum AutomaticEventType: String, Sendable {
    case flowStarted = "flow_start"
    case flowCompleted = "flow_complete"
    case flowDismissed = "flow_exit"
    case screenViewed = "screen_view"
    case screenExited = "screen_exit"
    case experimentAssigned = "experiment_exposure"
    case elementInteraction = "element_interaction"
}

// MARK: - Event Builder

/// Builder for creating analytics events
final class AnalyticsEventBuilder: @unchecked Sendable {
    private var appId: String = ""
    private var eventName: String
    private var placementId: String?
    private var flowId: String = ""
    private var flowVersionId: String = ""
    private var flowVersion: Int?
    private var experimentId: String?
    private var variantId: String?
    private var variantName: String?
    private var screenId: String?
    private var screenName: String?
    private var screenIndex: Int?
    private var elementId: String?
    private var elementType: String?
    private var interactionType: String?
    private var revenue: Double?
    private var currency: String?
    private var timeSinceFlowStartMs: Int?
    private var timeOnScreenMs: Int?
    private var properties: [String: Any]?

    init(appId: String = "", eventName: String) {
        self.appId = appId
        self.eventName = eventName
    }

    init(appId: String = "", eventType: AutomaticEventType) {
        self.appId = appId
        self.eventName = eventType.rawValue
    }

    @discardableResult
    func withAppId(_ id: String) -> Self {
        self.appId = id
        return self
    }

    @discardableResult
    func withPlacementId(_ id: String?) -> Self {
        self.placementId = id
        return self
    }

    @discardableResult
    func withFlowContext(
        flowId: String,
        flowVersionId: String,
        flowVersion: Int? = nil
    ) -> Self {
        self.flowId = flowId
        self.flowVersionId = flowVersionId
        self.flowVersion = flowVersion
        return self
    }

    @discardableResult
    func withExperiment(
        experimentId: String?,
        variantId: String?,
        variantName: String?
    ) -> Self {
        self.experimentId = experimentId
        self.variantId = variantId
        self.variantName = variantName
        return self
    }

    @discardableResult
    func withScreen(
        screenId: String?,
        screenName: String?,
        screenIndex: Int?
    ) -> Self {
        self.screenId = screenId
        self.screenName = screenName
        self.screenIndex = screenIndex
        return self
    }

    @discardableResult
    func withElement(
        elementId: String?,
        elementType: String?,
        interactionType: String?
    ) -> Self {
        self.elementId = elementId
        self.elementType = elementType
        self.interactionType = interactionType
        return self
    }

    @discardableResult
    func withRevenue(_ revenue: Double?, currency: String?) -> Self {
        self.revenue = revenue
        self.currency = currency
        return self
    }

    @discardableResult
    func withTiming(
        timeSinceFlowStartMs: Int?,
        timeOnScreenMs: Int?
    ) -> Self {
        self.timeSinceFlowStartMs = timeSinceFlowStartMs
        self.timeOnScreenMs = timeOnScreenMs
        return self
    }

    @discardableResult
    func withProperties(_ properties: [String: Any]?) -> Self {
        self.properties = properties
        return self
    }

    func build() -> AnalyticsEvent {
        let session = SessionManager.shared

        return AnalyticsEvent(
            appId: appId,
            eventName: eventName,
            placementId: placementId,
            flowId: flowId,
            flowVersionId: flowVersionId,
            userId: session.userId,
            sessionId: session.sessionId,
            flowVersion: flowVersion,
            experimentId: experimentId,
            variantId: variantId,
            variantName: variantName,
            screenId: screenId,
            screenName: screenName,
            screenIndex: screenIndex,
            elementId: elementId,
            elementType: elementType,
            interactionType: interactionType,
            revenue: revenue,
            currency: currency,
            timeSinceFlowStartMs: timeSinceFlowStartMs,
            timeOnScreenMs: timeOnScreenMs,
            properties: properties
        )
    }
}

// MARK: - SDK Version

public enum FlowPilotSDK {
    public static let version = "1.3.1"
}
