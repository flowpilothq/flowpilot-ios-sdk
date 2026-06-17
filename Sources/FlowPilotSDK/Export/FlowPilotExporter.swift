import Foundation

// MARK: - FlowPilot Offline Exporter

/// Build-time tool that snapshots the **currently live** flow at a placement into
/// a self-contained `.flowassets` folder you can drop into your app target as a
/// Tier-3 offline default.
///
/// It is the exact reverse of the runtime seeder (`BundledAssetSeeder`): it calls
/// the resolve endpoint (with `?export=true`, so the backend returns the
/// deterministic default flow rather than an A/B variant), enumerates the flow's
/// images / Lucide icons / fonts with the **same** resolvers the renderer uses,
/// downloads them, and writes `flow.json` + `manifest.json` + the asset files.
///
/// Output layout:
/// ```
/// <out>/
///   flow.json        # raw resolve response
///   manifest.json    # remote URL -> local file map
///   images/…  icons/…  fonts/…
/// ```
///
/// Designed to run on a dev machine or in CI (e.g. via the `flowpilot-export`
/// CLI). Per-asset download failures are non-fatal — they're logged and counted,
/// so a partial export still produces a usable bundle.
public enum FlowPilotExporter {

    // MARK: Config / Result

    public struct Config: Sendable {
        /// API base URL including version, e.g. `https://api.flowpilot.io/v1`.
        public var baseURL: String
        /// Workspace API key (`fp_…`).
        public var apiKey: String
        public var appId: String
        public var placement: String
        /// Target platform to export for (must be in the placement's platforms).
        public var platform: String
        /// Synthetic identifiers for the resolve call (export ignores assignment).
        public var userId: String
        public var sessionId: String

        public init(
            baseURL: String,
            apiKey: String,
            appId: String,
            placement: String,
            platform: String = "ios",
            userId: String = "flowpilot-offline-export",
            sessionId: String = "flowpilot-offline-export"
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.appId = appId
            self.placement = placement
            self.platform = platform
            self.userId = userId
            self.sessionId = sessionId
        }
    }

    public struct Summary: Sendable {
        public let placement: String
        public let flowId: String
        public let images: Int
        public let icons: Int
        public let fonts: Int
        public let imageFailures: Int
        public let iconFailures: Int
        public let fontFailures: Int
        public let outputPath: String
    }

    public enum ExportError: Error, CustomStringConvertible {
        case invalidURL(String)
        case httpError(Int, String)
        case noFlow
        case decodeFailed

        public var description: String {
            switch self {
            case .invalidURL(let s): return "invalid URL: \(s)"
            case .httpError(let code, let body): return "resolve failed (HTTP \(code)): \(body)"
            case .noFlow: return "no flow is live at this placement (resolve returned no flow)"
            case .decodeFailed: return "could not decode the resolve response into a flow"
            }
        }
    }

    // MARK: Export

    /// Run the export. Returns a `Summary`; throws only on fatal errors
    /// (resolve failed / no flow / can't write output). Per-asset failures are
    /// logged via `log` and reflected in the summary's failure counts.
    @discardableResult
    public static func export(
        _ config: Config,
        to outputDirectory: URL,
        session: URLSession = .shared,
        log: @escaping (String) -> Void = { print($0) }
    ) async throws -> Summary {
        // 1. Resolve the live flow (deterministic default, no A/B assignment).
        let responseData = try await fetchResolve(config, session: session)

        // 2a. Explicit "no flow live at this placement" detection: the resolve
        // endpoint returns `flow_id: null` when nothing matches.
        if let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            let flowId = obj["flow_id"] ?? NSNull()
            if flowId is NSNull { throw ExportError.noFlow }
        }

        // 2b. Decode into a flow so we can enumerate its assets.
        guard let flow = BundledFlowProvider.decode(responseData) else {
            throw ExportError.decodeFailed
        }

        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 3. Write the raw resolve response as flow.json (what the seeder reads).
        try responseData.write(to: outputDirectory.appendingPathComponent("flow.json"))
        log("flow.json  (flowId: \(flow.flowId), version: \(flow.flowVersion))")

        // 4. Enumerate + download each asset class.
        let (imageEntries, imageFailures) = await downloadImages(flow, into: outputDirectory, session: session, log: log)
        let (iconEntries, iconFailures) = await downloadIcons(flow, into: outputDirectory, session: session, log: log)
        let (fontEntries, fontFailures) = await downloadFonts(flow, into: outputDirectory, session: session, log: log)

        // 5. Write the manifest (the exact type the runtime seeder decodes).
        let manifest = BundledAssetManifest(images: imageEntries, icons: iconEntries, fonts: fontEntries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: outputDirectory.appendingPathComponent("manifest.json"))
        log("manifest.json  (\(imageEntries.count) images, \(iconEntries.count) icons, \(fontEntries.count) fonts)")

        return Summary(
            placement: config.placement,
            flowId: flow.flowId,
            images: imageEntries.count,
            icons: iconEntries.count,
            fonts: fontEntries.count,
            imageFailures: imageFailures,
            iconFailures: iconFailures,
            fontFailures: fontFailures,
            outputPath: outputDirectory.path
        )
    }

    // MARK: - Per-class downloads

    private static func downloadImages(
        _ flow: ResolvedFlow, into dir: URL, session: URLSession, log: (String) -> Void
    ) async -> ([BundledAssetManifest.ImageEntry], Int) {
        let urls = FlowAssetEnumerator.imageURLs(in: flow)
        guard !urls.isEmpty else { return ([], 0) }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)

        var entries: [BundledAssetManifest.ImageEntry] = []
        var failures = 0
        for (index, url) in urls.enumerated() {
            let resource = "images/\(index)-\(safeFilename(url.lastPathComponent, fallback: "image"))"
            if await download(url, to: dir.appendingPathComponent(resource), session: session, log: log) {
                entries.append(.init(url: url.absoluteString, resource: resource))
                log("image  \(url.absoluteString)")
            } else {
                failures += 1
            }
        }
        return (entries, failures)
    }

    private static func downloadIcons(
        _ flow: ResolvedFlow, into dir: URL, session: URLSession, log: (String) -> Void
    ) async -> ([BundledAssetManifest.IconEntry], Int) {
        let urls = FlowAssetEnumerator.iconURLs(in: flow)
        guard !urls.isEmpty else { return ([], 0) }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("icons"), withIntermediateDirectories: true)

        var entries: [BundledAssetManifest.IconEntry] = []
        var failures = 0
        for url in urls {
            let resource = "icons/\(safeFilename(url.lastPathComponent, fallback: "icon.svg"))"
            if await download(url, to: dir.appendingPathComponent(resource), session: session, log: log) {
                entries.append(.init(url: url.absoluteString, resource: resource))
                log("icon   \(url.absoluteString)")
            } else {
                failures += 1
            }
        }
        return (entries, failures)
    }

    private static func downloadFonts(
        _ flow: ResolvedFlow, into dir: URL, session: URLSession, log: (String) -> Void
    ) async -> ([BundledAssetManifest.FontEntry], Int) {
        let fonts = FlowAssetEnumerator.fontFiles(in: flow)
        guard !fonts.isEmpty else { return ([], 0) }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("fonts"), withIntermediateDirectories: true)

        var entries: [BundledAssetManifest.FontEntry] = []
        var failures = 0
        for font in fonts {
            guard let url = URL(string: font.url) else { failures += 1; continue }
            let resource = "fonts/\(safeFilename(font.cacheKey, fallback: "font")).ttf"
            if await download(url, to: dir.appendingPathComponent(resource), session: session, log: log) {
                entries.append(.init(family: font.family, weight: font.weight, style: font.style, resource: resource))
                log("font   \(font.family) \(font.weight)  \(url.absoluteString)")
            } else {
                failures += 1
            }
        }
        return (entries, failures)
    }

    // MARK: - Networking

    private static func fetchResolve(_ config: Config, session: URLSession) async throws -> Data {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        let path = "\(base)/apps/\(config.appId)/placements/\(config.placement)/resolve?export=true"
        guard let url = URL(string: path) else { throw ExportError.invalidURL(path) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "user_id": config.userId,
            "session_id": config.sessionId,
            "device_platform": config.platform
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ExportError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Download one asset to a file. Returns false (non-fatal) on any error.
    private static func download(_ url: URL, to fileURL: URL, session: URLSession, log: (String) -> Void) async -> Bool {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                log("! skip \(url.absoluteString) (HTTP \(http.statusCode))")
                return false
            }
            try data.write(to: fileURL)
            return true
        } catch {
            log("! skip \(url.absoluteString) (\(error.localizedDescription))")
            return false
        }
    }

    /// A safe, single-path-component filename. URL.lastPathComponent already
    /// strips the query; this guards against empty / separator-only values.
    private static func safeFilename(_ name: String, fallback: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
    }
}
