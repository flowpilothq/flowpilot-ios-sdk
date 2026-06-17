import Foundation

// MARK: - Bundled Flow Provider

/// Loads and caches build-time "default" flows used as an offline fallback
/// (resolution Tier 3).
///
/// A bundled flow is the JSON a developer exports from the FlowPilot editor and
/// ships inside their app bundle. When the network resolve fails *and* there is
/// no usable cache, the SDK renders this bundled flow instead — so a
/// FlowPilot-rendered onboarding still runs with no network and no prior cache.
///
/// Accepts either a full resolve-response payload (preferred — it carries media
/// / icon base URLs and the font manifest) or a bare flow definition, which is
/// wrapped with synthetic identifiers.
final class BundledFlowProvider: @unchecked Sendable {
    /// placementKey -> closure that loads the raw JSON data on demand. Lazy so
    /// we never touch disk for placements that resolve normally.
    private var loaders: [String: () -> Data?] = [:]
    /// Decoded + validated flows, memoized after first successful load.
    private var decodedFlows: [String: ResolvedFlow] = [:]
    /// Placements already attempted and failed, so invalid JSON isn't re-parsed
    /// on every resolve failure.
    private var failed: Set<String> = []
    /// placementKey -> offline image/font assets to seed before presenting the
    /// bundled flow. Optional: a bundled flow without assets still renders, just
    /// with remote images / system-font fallback when offline.
    private var assetSources: [String: BundledFlowAssets] = [:]
    private let lock = NSLock()

    var hasAnyFlows: Bool {
        lock.lock(); defer { lock.unlock() }
        return !loaders.isEmpty
    }

    // MARK: Registration

    /// Register a raw-data loader for a placement.
    func register(placementKey: String, dataLoader: @escaping () -> Data?) {
        lock.lock(); defer { lock.unlock() }
        loaders[placementKey] = dataLoader
        decodedFlows.removeValue(forKey: placementKey)
        failed.remove(placementKey)
    }

    /// Register a JSON resource shipped in a bundle, optionally inside a
    /// subdirectory (e.g. a `.flowassets` folder reference).
    func registerResource(
        placementKey: String,
        resource: String,
        withExtension ext: String,
        subdirectory: String? = nil,
        in bundle: Bundle
    ) {
        register(placementKey: placementKey) {
            guard let url = bundle.url(forResource: resource, withExtension: ext, subdirectory: subdirectory) else {
                let loc = subdirectory.map { " (subdirectory '\($0)')" } ?? ""
                Logger.shared.warn("BundledFlowProvider: resource '\(resource).\(ext)'\(loc) not found in bundle for placement '\(placementKey)'")
                return nil
            }
            return try? Data(contentsOf: url)
        }
    }

    /// Register an in-memory JSON payload directly.
    func register(placementKey: String, json: Data) {
        register(placementKey: placementKey) { json }
    }

    /// Register the offline image/font assets to seed for a placement's bundled flow.
    func register(placementKey: String, assets: BundledFlowAssets) {
        lock.lock(); defer { lock.unlock() }
        assetSources[placementKey] = assets
    }

    /// The registered offline assets for a placement, if any.
    func assets(for placementKey: String) -> BundledFlowAssets? {
        lock.lock(); defer { lock.unlock() }
        return assetSources[placementKey]
    }

    // MARK: Lookup

    /// Return the bundled flow for a placement, decoding lazily on first use.
    /// Returns nil if no bundled flow is registered, the data can't be loaded,
    /// or the JSON can't be decoded into a presentable flow.
    func flow(for placementKey: String) -> ResolvedFlow? {
        lock.lock()
        if let cached = decodedFlows[placementKey] {
            lock.unlock()
            return cached
        }
        if failed.contains(placementKey) {
            lock.unlock()
            return nil
        }
        let loader = loaders[placementKey]
        lock.unlock()

        guard let loader, let data = loader() else {
            markFailed(placementKey)
            return nil
        }

        guard let flow = BundledFlowProvider.decode(data), flow.validateForPresentation() else {
            Logger.shared.warn("BundledFlowProvider: bundled flow for placement '\(placementKey)' is missing, malformed, or not presentable")
            markFailed(placementKey)
            return nil
        }

        lock.lock(); decodedFlows[placementKey] = flow; lock.unlock()
        Logger.shared.info("BundledFlowProvider: loaded bundled default flow for placement '\(placementKey)' (flowId: \(flow.flowId))")
        return flow
    }

    private func markFailed(_ placementKey: String) {
        lock.lock(); failed.insert(placementKey); lock.unlock()
    }

    // MARK: Asset Seeding

    /// Seed the image/font caches from the placement's registered offline assets,
    /// so the bundled flow's first paint uses local bytes instead of the network.
    /// No-op when no assets are registered. Best-effort and never throws.
    func seedAssets(for placementKey: String, flow: ResolvedFlow) async {
        guard let assets = assets(for: placementKey) else { return }
        await BundledAssetSeeder.seed(flow: flow, assets: assets)
    }

    // MARK: Decoding

    /// Decode bundled JSON into a `ResolvedFlow`. Tries the resolve-response
    /// shape first (so bundled assets/fonts carry through), then falls back to a
    /// bare `FlowDefinition`.
    static func decode(_ data: Data) -> ResolvedFlow? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        // 1) Full resolve-response payload.
        if let response = try? decoder.decode(ResolveResponse.self, from: data),
           response.hasFlow,
           let flow = try? ResolvedFlow(from: response) {
            return flow
        }

        // 2) Bare flow definition.
        if let definition = try? decoder.decode(FlowDefinition.self, from: data) {
            return ResolvedFlow(
                flowId: definition.id.isEmpty ? "bundled_default" : definition.id,
                flowVersionId: "bundled",
                flowVersion: definition.version,
                schemaVersion: definition.schemaVersion,
                definition: definition
            )
        }

        return nil
    }
}
