import Foundation

// MARK: - Flow Cache

/// Multi-layer cache for flow data (memory + disk)
final class FlowCache: @unchecked Sendable {
    private let memoryCache: MemoryCache<ResolvedFlow>
    private let diskCache: DiskCache
    private let enabled: Bool

    init(enabled: Bool = true, cacheDirectory: String? = nil) {
        self.enabled = enabled
        self.memoryCache = MemoryCache(maxSize: 50)
        self.diskCache = DiskCache(directory: cacheDirectory)
    }

    // MARK: - Public API

    /// Get a **fresh** cached flow by placement ID (Tier 0).
    /// Returns nil when the entry is missing or its freshness TTL has lapsed —
    /// but a lapsed entry is left on disk so `getStaleFlow` can still serve it
    /// as a last-known-good fallback when the network is unavailable.
    ///
    /// `fingerprint` ties the lookup to the identity + targeting attributes the
    /// flow was resolved under (see `ResolveFingerprint`), so a fresh hit is only
    /// returned for the *same* identity — never a wrong-targeting / wrong-variant
    /// flow resolved under a different user or attribute set.
    func getFlow(placementId: String, fingerprint: String) -> ResolvedFlow? {
        return getFreshFlow(placementId: placementId, fingerprint: fingerprint)?.flow
    }

    /// Like `getFlow` (Tier 0), but also reports how much of the freshness TTL
    /// remains, so callers can implement stale-while-revalidate: serve the fresh
    /// hit immediately and, when it's close to expiry, refresh the cache in the
    /// background for the next caller. Same identity rules as `getFlow` — only the
    /// `fingerprint`-matched entry is returned, never a wrong-identity flow.
    func getFreshFlow(placementId: String, fingerprint: String) -> (flow: ResolvedFlow, ttlRemaining: TimeInterval)? {
        guard enabled else { return nil }

        let key = cacheKey(placementId: placementId, fingerprint: fingerprint)

        // Check memory first (memory only returns non-expired entries).
        if let hit = memoryCache.getWithRemaining(key) {
            Logger.shared.debug("Cache hit (memory): \(placementId)")
            return (hit.value, hit.remaining)
        }

        // Check disk without deleting on expiry; treat as a hit only if fresh.
        if let cached: CachedItem<ResolvedFlow> = diskCache.getAllowingStale(key) {
            if cached.isExpired {
                Logger.shared.debug("Cache present but stale (disk): \(placementId)")
                return nil
            }
            Logger.shared.debug("Cache hit (disk): \(placementId)")
            let ttlRemaining = cached.ttlRemaining
            if ttlRemaining > 0 {
                memoryCache.set(key, value: cached.value, ttl: ttlRemaining)
            }
            return (cached.value, ttlRemaining)
        }

        Logger.shared.debug("Cache miss: \(placementId)")
        return nil
    }

    /// Get the last successfully-resolved flow for a placement **regardless of
    /// freshness** (Tier 2). Used as a fallback when a live resolve fails or
    /// times out, so onboarding still renders the last good experience offline.
    ///
    /// Resilience rule: the identity-matched (`fingerprint`) entry is preferred,
    /// but if there is none — e.g. the user's identity changed since the last
    /// successful resolve and we're now offline — this falls back to the
    /// fingerprint-agnostic "last good" alias written by `setFlow`. That keeps
    /// today's offline behavior intact across an identity change, while fresh
    /// (Tier 0) hits stay strictly identity-correct.
    func getStaleFlow(placementId: String, fingerprint: String) -> ResolvedFlow? {
        guard enabled else { return nil }

        let key = cacheKey(placementId: placementId, fingerprint: fingerprint)
        if let cached: CachedItem<ResolvedFlow> = diskCache.getAllowingStale(key) {
            Logger.shared.debug("Stale cache hit (disk): \(placementId), age=\(cached.isExpired ? "expired" : "fresh")")
            return cached.value
        }

        // Offline last resort: any last-known-good entry for this placement,
        // regardless of the identity it was resolved under.
        let lastKey = lastGoodKey(placementId: placementId)
        if let cached: CachedItem<ResolvedFlow> = diskCache.getAllowingStale(lastKey) {
            Logger.shared.debug("Stale cache hit via last-good alias (disk): \(placementId), age=\(cached.isExpired ? "expired" : "fresh")")
            return cached.value
        }
        return nil
    }

    /// Get a cached flow by flow ID and version
    func getFlow(flowId: String, versionId: String) -> ResolvedFlow? {
        guard enabled else { return nil }

        let key = cacheKey(flowId: flowId, versionId: versionId)

        if let flow = memoryCache.get(key) {
            return flow
        }

        if let cached: CachedItem<ResolvedFlow> = diskCache.getAllowingStale(key) {
            if cached.isExpired { return nil }
            let ttlRemaining = cached.ttlRemaining
            if ttlRemaining > 0 {
                memoryCache.set(key, value: cached.value, ttl: ttlRemaining)
            }
            return cached.value
        }

        return nil
    }

    /// Cache a resolved flow.
    ///
    /// When `placementId` is provided, the flow is stored under the
    /// identity-scoped key (`placement:<id>:<fingerprint>`) used by fresh Tier-0
    /// lookups, and *also* under a fingerprint-agnostic "last good" alias
    /// (`placement:<id>:_last`) that always points at the most recent successful
    /// resolve. The alias is the offline safety net read by `getStaleFlow` when
    /// the current identity has no matching entry.
    func setFlow(_ flow: ResolvedFlow, placementId: String?, fingerprint: String) {
        guard enabled else { return }

        let ttl = TimeInterval(flow.cacheTtlSeconds)

        // Cache by flow ID + version
        let flowKey = cacheKey(flowId: flow.flowId, versionId: flow.flowVersionId)
        memoryCache.set(flowKey, value: flow, ttl: ttl)
        diskCache.set(flowKey, value: flow, ttl: ttl)

        // Also cache by placement if provided
        if let placementId = placementId {
            let placementKey = cacheKey(placementId: placementId, fingerprint: fingerprint)
            memoryCache.set(placementKey, value: flow, ttl: ttl)
            diskCache.set(placementKey, value: flow, ttl: ttl)

            // Fingerprint-agnostic last-known-good alias for offline fallback.
            let lastKey = lastGoodKey(placementId: placementId)
            memoryCache.set(lastKey, value: flow, ttl: ttl)
            diskCache.set(lastKey, value: flow, ttl: ttl)
        }

        Logger.shared.debug("Cached flow \(flow.flowId) with TTL \(ttl)s")
    }

    /// Remove a cached flow for a placement + identity, along with its
    /// fingerprint-agnostic last-known-good alias.
    func removeFlow(placementId: String, fingerprint: String) {
        let key = cacheKey(placementId: placementId, fingerprint: fingerprint)
        memoryCache.remove(key)
        diskCache.remove(key)

        let lastKey = lastGoodKey(placementId: placementId)
        memoryCache.remove(lastKey)
        diskCache.remove(lastKey)
    }

    /// Clear all cached flows
    func clear() {
        memoryCache.clear()
        diskCache.clear()
        Logger.shared.info("Cache cleared")
    }

    /// Clean expired entries
    func cleanExpired() {
        diskCache.cleanExpired()
    }

    // MARK: - Cache Keys

    /// Identity-scoped placement key. The `fingerprint` ensures a fresh hit is
    /// only reused for the same identity + targeting attributes (see
    /// `ResolveFingerprint`).
    private func cacheKey(placementId: String, fingerprint: String) -> String {
        return "placement:\(placementId):\(fingerprint)"
    }

    /// Fingerprint-agnostic "last known good" alias for a placement. Always
    /// points at the most recent successful resolve so `getStaleFlow` can serve
    /// *something* offline even after an identity change.
    private func lastGoodKey(placementId: String) -> String {
        return "placement:\(placementId):_last"
    }

    private func cacheKey(flowId: String, versionId: String) -> String {
        return "flow:\(flowId):\(versionId)"
    }
}

// MARK: - ResolvedFlow Codable

extension ResolvedFlow: Codable {
    enum CodingKeys: String, CodingKey {
        case flowId, flowVersionId, flowVersion, schemaVersion
        case definition, mediaBaseUrl, iconBaseUrl, fonts, experimentId, variantId, variantName
        case cacheTtlSeconds, resolvedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flowId = try container.decode(String.self, forKey: .flowId)
        flowVersionId = try container.decode(String.self, forKey: .flowVersionId)
        flowVersion = try container.decode(Int.self, forKey: .flowVersion)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        definition = try container.decode(FlowDefinition.self, forKey: .definition)
        mediaBaseUrl = try container.decodeIfPresent(String.self, forKey: .mediaBaseUrl)
        _iconBaseUrl = try container.decodeIfPresent(String.self, forKey: .iconBaseUrl)
        fonts = try container.decodeIfPresent([FontFile].self, forKey: .fonts)
        experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        variantId = try container.decodeIfPresent(String.self, forKey: .variantId)
        variantName = try container.decodeIfPresent(String.self, forKey: .variantName)
        cacheTtlSeconds = try container.decode(Int.self, forKey: .cacheTtlSeconds)
        resolvedAt = try container.decode(Date.self, forKey: .resolvedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(flowId, forKey: .flowId)
        try container.encode(flowVersionId, forKey: .flowVersionId)
        try container.encode(flowVersion, forKey: .flowVersion)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(definition, forKey: .definition)
        try container.encodeIfPresent(mediaBaseUrl, forKey: .mediaBaseUrl)
        try container.encodeIfPresent(_iconBaseUrl, forKey: .iconBaseUrl)
        try container.encodeIfPresent(fonts, forKey: .fonts)
        try container.encodeIfPresent(experimentId, forKey: .experimentId)
        try container.encodeIfPresent(variantId, forKey: .variantId)
        try container.encodeIfPresent(variantName, forKey: .variantName)
        try container.encode(cacheTtlSeconds, forKey: .cacheTtlSeconds)
        try container.encode(resolvedAt, forKey: .resolvedAt)
    }
}
