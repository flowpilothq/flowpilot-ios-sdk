import Foundation

// MARK: - Resolve Serving

/// Abstraction over the network resolve calls so the resolve path can be mocked
/// in tests (e.g. to count how many times a placement is actually resolved,
/// proving in-flight coalescing). `FlowPilot` depends on this protocol rather
/// than the concrete `ResolveService`, and constructs the real `ResolveService`
/// by default.
///
/// Both methods perform a single network round-trip and return the decoded
/// `ResolveResponse`; caching, deadlines, and validation are layered on top by
/// `FlowPilot`, not here.
protocol ResolveServing: Sendable {
    /// Resolve a flow for a placement, personalized by `userId` + `attributes`.
    func resolvePlacement(
        placementId: String,
        userId: String,
        sessionId: String,
        attributes: [String: Any]?
    ) async throws -> ResolveResponse

    /// Resolve several placements for one identity in a single round-trip.
    ///
    /// The identity (`userId` + `attributes`) applies to every placement, just
    /// as `resolvePlacement` personalizes a single one. Returns one
    /// `ResolveResponse` per placement key that resolved to *something* (a flow
    /// or an explicit no-flow); placements the backend failed to resolve are
    /// simply absent from the map. Used by launch prefetch to warm many
    /// placements without N separate requests; the caller treats a thrown error
    /// (e.g. the endpoint being unavailable) as "fall back to per-placement
    /// resolves."
    func resolveBatch(
        placementIds: [String],
        userId: String,
        sessionId: String,
        attributes: [String: Any]?
    ) async throws -> [String: ResolveResponse]

    /// Resolve a specific flow by its ID (not personalized by attributes).
    func resolveFlow(
        flowId: String,
        userId: String,
        sessionId: String
    ) async throws -> ResolveResponse
}

// MARK: - Resolve Service

/// Service for resolving flows from placements
final class ResolveService: ResolveServing, @unchecked Sendable {
    private let apiClient: APIClient
    private let appId: String

    init(apiClient: APIClient, appId: String) {
        self.apiClient = apiClient
        self.appId = appId
    }

    // MARK: - Resolve Placement

    /// Resolve a flow for a placement
    func resolvePlacement(
        placementId: String,
        userId: String,
        sessionId: String,
        attributes: [String: Any]?
    ) async throws -> ResolveResponse {
        let request = ResolveRequest(
            userId: userId,
            sessionId: sessionId,
            devicePlatform: "ios",
            attributes: attributes?.mapValues { AnyCodable($0) }
        )

        let response: ResolveResponse = try await apiClient.request(
            method: .POST,
            path: "/apps/\(appId)/placements/\(placementId)/resolve",
            body: request
        )

        return response
    }

    /// Resolve several placements for one identity in a single round-trip.
    func resolveBatch(
        placementIds: [String],
        userId: String,
        sessionId: String,
        attributes: [String: Any]?
    ) async throws -> [String: ResolveResponse] {
        let request = BatchResolveRequest(
            placementKeys: placementIds,
            userId: userId,
            sessionId: sessionId,
            devicePlatform: "ios",
            attributes: attributes?.mapValues { AnyCodable($0) }
        )

        let response: BatchResolveResponse = try await apiClient.request(
            method: .POST,
            path: "/apps/\(appId)/placements/resolve-batch",
            body: request
        )

        // Key results by placement so callers can correlate regardless of order.
        // A placement that failed to resolve carries an `error` and a nil flow —
        // drop it so the caller falls back to a per-placement resolve for it.
        var byKey: [String: ResolveResponse] = [:]
        for result in response.results where result.error == nil {
            byKey[result.placementKey] = result.response
        }
        return byKey
    }

    /// Resolve a specific flow by ID
    func resolveFlow(
        flowId: String,
        userId: String,
        sessionId: String
    ) async throws -> ResolveResponse {
        let request = ResolveRequest(
            userId: userId,
            sessionId: sessionId,
            devicePlatform: "ios",
            attributes: nil
        )

        let response: ResolveResponse = try await apiClient.request(
            method: .POST,
            path: "/apps/\(appId)/flows/\(flowId)/resolve",
            body: request
        )

        return response
    }
}

// MARK: - Request/Response Models

struct ResolveRequest: Encodable {
    let userId: String
    let sessionId: String
    let devicePlatform: String
    let attributes: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case sessionId = "session_id"
        case devicePlatform = "device_platform"
        case attributes
    }
}

// MARK: - Batch Resolve Models

/// Resolve several placements for one identity in a single request. The identity
/// fields apply to every key in `placementKeys`.
struct BatchResolveRequest: Encodable {
    let placementKeys: [String]
    let userId: String
    let sessionId: String
    let devicePlatform: String
    let attributes: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case placementKeys = "placement_keys"
        case userId = "user_id"
        case sessionId = "session_id"
        case devicePlatform = "device_platform"
        case attributes
    }
}

/// One placement's batch result: the same shape a single resolve returns, tagged
/// with its placement key (and an optional per-placement `error`, set when only
/// that placement failed to resolve).
struct BatchResolveResult: Decodable, Sendable {
    let placementKey: String
    let response: ResolveResponse
    let error: String?

    // The APIClient decodes with `.convertFromSnakeCase`, so `placement_key`
    // arrives as `placementKey`. The embedded resolve fields (`flowId`,
    // `flowSchema`, …) live at the same level, so the `ResolveResponse` is
    // decoded from the same decoder/object.
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case placementKey
            case error
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        placementKey = try container.decode(String.self, forKey: .placementKey)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        response = try ResolveResponse(from: decoder)
    }
}

/// The batch-resolve envelope: one `BatchResolveResult` per requested placement.
struct BatchResolveResponse: Decodable, Sendable {
    let results: [BatchResolveResult]
}

/// Response from the resolve API
struct ResolveResponse: Decodable, Sendable {
    /// Flow ID (null if no flow should show)
    let flowId: String?

    /// Flow version ID
    let flowVersionId: String?

    /// Flow version number
    let flowVersion: Int?

    /// Schema version (can be int or string from API)
    let schemaVersion: String?

    /// Complete flow definition
    let flowSchema: FlowDefinition?

    /// CDN URL prefix for media assets
    let mediaBaseUrl: String?

    /// CDN URL prefix for Lucide icon SVGs (e.g. https://cdn.flowpilot.com/icons)
    let iconBaseUrl: String?

    /// Experiment ID (if in A/B test)
    let experimentId: String?

    /// Variant ID (if in A/B test)
    let variantId: String?

    /// Human-readable variant name
    let variantName: String?

    /// Client-side cache TTL in seconds
    let cacheTtlSeconds: Int?

    /// Font files required by this flow (CDN URLs for custom fonts)
    let fonts: [FontFile]?

    // Note: No CodingKeys needed - APIClient uses .convertFromSnakeCase

    init(from decoder: Decoder) throws {
        // Use camelCase keys since decoder converts from snake_case automatically
        enum CodingKeys: String, CodingKey {
            case flowId, flowVersionId, flowVersion, schemaVersion, flowSchema
            case mediaBaseUrl, iconBaseUrl, experimentId, variantId, variantName, cacheTtlSeconds
            case fonts
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        flowId = try container.decodeIfPresent(String.self, forKey: .flowId)
        flowVersionId = try container.decodeIfPresent(String.self, forKey: .flowVersionId)
        flowVersion = try container.decodeIfPresent(Int.self, forKey: .flowVersion)
        flowSchema = try container.decodeIfPresent(FlowDefinition.self, forKey: .flowSchema)
        mediaBaseUrl = try container.decodeIfPresent(String.self, forKey: .mediaBaseUrl)
        iconBaseUrl = try container.decodeIfPresent(String.self, forKey: .iconBaseUrl)
        Logger.shared.info("[ICON DEBUG] ResolveResponse.decode: iconBaseUrl = \(iconBaseUrl ?? "nil")")
        experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        variantId = try container.decodeIfPresent(String.self, forKey: .variantId)
        variantName = try container.decodeIfPresent(String.self, forKey: .variantName)
        cacheTtlSeconds = try container.decodeIfPresent(Int.self, forKey: .cacheTtlSeconds)
        fonts = try container.decodeIfPresent([FontFile].self, forKey: .fonts)
        Logger.shared.info("[FONT DEBUG] ResolveResponse.decode: fonts decoded = \(fonts?.count ?? -1) (-1 means nil)")
        if let fonts = fonts {
            for f in fonts {
                Logger.shared.info("[FONT DEBUG] ResolveResponse.decode: font — family=\(f.family) weight=\(f.weight) url=\(f.url)")
            }
        }

        // Handle schemaVersion as either String or Int
        if let stringVersion = try? container.decodeIfPresent(String.self, forKey: .schemaVersion) {
            schemaVersion = stringVersion
        } else if let intVersion = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion) {
            schemaVersion = "\(intVersion).0.0"
        } else {
            schemaVersion = nil
        }
    }

    /// Whether a flow was resolved
    var hasFlow: Bool {
        return flowId != nil && flowSchema != nil
    }
}

// MARK: - Resolved Flow

/// A fully resolved flow with all metadata
public struct ResolvedFlow: Sendable {
    public let flowId: String
    public let flowVersionId: String
    public let flowVersion: Int
    public let schemaVersion: String
    public let definition: FlowDefinition
    public let mediaBaseUrl: String?
    let _iconBaseUrl: String?
    public let fonts: [FontFile]?

    /// Icon base URL. When the backend provides it explicitly, that value is used.
    /// Otherwise, derives it from `mediaBaseUrl` by stripping the workspace path
    /// segment and appending `/icons`.
    /// e.g. `https://cdn.flowpilot.com/{workspaceId}` → `https://cdn.flowpilot.com/icons`
    public var iconBaseUrl: String? {
        if let explicit = _iconBaseUrl { return explicit }
        guard let media = mediaBaseUrl, let url = URL(string: media) else { return nil }
        // mediaBaseUrl is "{cdnBase}/{workspaceId}" — drop the last path component
        let base = url.deletingLastPathComponent().absoluteString
        // Remove trailing slash and append /icons
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return "\(trimmed)/icons"
    }
    public let experimentId: String?
    public let variantId: String?
    public let variantName: String?
    public let cacheTtlSeconds: Int
    public let resolvedAt: Date

    /// Creates a ResolvedFlow directly from a FlowDefinition.
    /// Used by the FlowPilot Preview app to bypass placement resolution.
    public init(
        flowId: String,
        flowVersionId: String,
        flowVersion: Int = 1,
        schemaVersion: String = "1.0.0",
        definition: FlowDefinition,
        mediaBaseUrl: String? = nil,
        iconBaseUrl: String? = nil,
        fonts: [FontFile]? = nil,
        experimentId: String? = nil,
        variantId: String? = nil,
        variantName: String? = nil,
        cacheTtlSeconds: Int = 0
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
        self.resolvedAt = Date()
    }

    init(from response: ResolveResponse) throws {
        guard let flowId = response.flowId,
              let flowVersionId = response.flowVersionId,
              let flowSchema = response.flowSchema else {
            Logger.shared.error("No flow in response - flowId: \(response.flowId ?? "nil"), flowVersionId: \(response.flowVersionId ?? "nil"), flowSchema: \(response.flowSchema != nil ? "present" : "nil")")
            throw FlowPilotError(code: .flowNotFound, message: "No flow in response - flowId: \(response.flowId ?? "nil"), flowVersionId: \(response.flowVersionId ?? "nil"), flowSchema: \(response.flowSchema != nil ? "present" : "nil")")
        }

        self.flowId = flowId
        self.flowVersionId = flowVersionId
        self.flowVersion = response.flowVersion ?? 1
        self.schemaVersion = response.schemaVersion ?? "1.0.0"
        self.definition = flowSchema
        self.mediaBaseUrl = response.mediaBaseUrl
        self._iconBaseUrl = response.iconBaseUrl
        self.fonts = response.fonts
        self.experimentId = response.experimentId
        self.variantId = response.variantId
        self.variantName = response.variantName
        self.cacheTtlSeconds = response.cacheTtlSeconds ?? 300
        self.resolvedAt = Date()
        Logger.shared.info("[ICON DEBUG] ResolvedFlow.init(from response): explicit = \(response.iconBaseUrl ?? "nil"), resolved = \(self.iconBaseUrl ?? "nil")")
    }

    /// Check if the schema version is supported.
    ///
    /// Only a **major** version bump is treated as incompatible — that's the
    /// signal that the wire format changed in a way an older SDK genuinely
    /// can't parse. A newer *minor/patch* schema renders best-effort: any
    /// component or node type this build doesn't recognize is skipped
    /// (see `ComponentType.unknown` and `FlowNode`'s pass-through default),
    /// so a forward flow never hard-fails on an additive change.
    func validateSchemaVersion() throws {
        guard majorVersion(schemaVersion) <= majorVersion(SchemaVersion.maxSupported) else {
            throw FlowPilotError.unsupportedSchemaVersion(
                required: schemaVersion,
                supported: SchemaVersion.maxSupported
            )
        }

        if compareVersions(schemaVersion, SchemaVersion.maxSupported) > 0 {
            Logger.shared.warn("Flow schema \(schemaVersion) is newer than SDK max \(SchemaVersion.maxSupported) (same major). Rendering best-effort; unrecognized components/nodes will be skipped.")
        }
    }
}

// MARK: - Major Version

/// Extract the leading (major) component of a semantic version string.
/// Defaults to 0 when the string has no parseable leading integer.
func majorVersion(_ version: String) -> Int {
    return version.split(separator: ".").first.flatMap { Int($0) } ?? 0
}

// MARK: - Version Comparison

/// Compare two semantic version strings
/// Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
func compareVersions(_ v1: String, _ v2: String) -> Int {
    let components1 = v1.split(separator: ".").compactMap { Int($0) }
    let components2 = v2.split(separator: ".").compactMap { Int($0) }

    let maxLength = max(components1.count, components2.count)

    for i in 0..<maxLength {
        let c1 = i < components1.count ? components1[i] : 0
        let c2 = i < components2.count ? components2[i] : 0

        if c1 < c2 { return -1 }
        if c1 > c2 { return 1 }
    }

    return 0
}
