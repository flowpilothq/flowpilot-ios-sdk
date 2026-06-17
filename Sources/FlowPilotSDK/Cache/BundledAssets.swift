import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Bundled Asset Manifest

/// Sidecar manifest shipped alongside a bundled (offline) default flow. Maps the
/// flow's remote image/font references to local files in the asset bundle so the
/// SDK can seed its caches without guessing filenames.
///
/// Expected JSON shape (see `HANDOFF_BUNDLED_FLOW_ASSETS.md`):
/// ```json
/// {
///   "images": [
///     { "url": "https://cdn.flowpilot.io/ws/hero.png", "resource": "images/hero.png" },
///     { "src": "hero.png", "resource": "images/hero.png" }
///   ],
///   "icons": [
///     { "url": "https://cdn.flowpilot.com/icons/Star.svg", "resource": "icons/Star.svg" }
///   ],
///   "fonts": [
///     { "family": "Inter", "weight": 700, "style": "normal", "resource": "fonts/Inter-700.ttf" }
///   ]
/// }
/// ```
/// `Codable` so the build-time exporter (`FlowPilotExporter`) writes the exact
/// type the runtime seeder reads — the format can't drift.
struct BundledAssetManifest: Codable {
    struct ImageEntry: Codable {
        /// Fully-resolved remote URL (preferred — exactly the render-time cache key).
        let url: String?
        /// Raw `src` re-resolved against the flow's `mediaBaseUrl` when `url` is absent.
        let src: String?
        /// Path to the local file, relative to the asset bundle directory.
        let resource: String

        init(url: String? = nil, src: String? = nil, resource: String) {
            self.url = url
            self.src = src
            self.resource = resource
        }
    }

    struct IconEntry: Codable {
        /// Fully-resolved Lucide SVG URL (preferred — exactly the render-time cache key).
        let url: String?
        /// Lucide icon name re-resolved against the flow's `iconBaseUrl` when `url` is absent.
        let name: String?
        /// Path to the local `.svg`, relative to the asset bundle directory.
        let resource: String

        init(url: String? = nil, name: String? = nil, resource: String) {
            self.url = url
            self.name = name
            self.resource = resource
        }
    }

    struct FontEntry: Codable {
        let family: String
        let weight: Int
        let style: String?
        /// Path to the local `.ttf`, relative to the asset bundle directory.
        let resource: String

        init(family: String, weight: Int, style: String?, resource: String) {
            self.family = family
            self.weight = weight
            self.style = style
            self.resource = resource
        }

        /// Mirrors `FontFile.cacheKey` so seeded fonts match the flow's manifest.
        var cacheKey: String { "\(family)-\(weight)" }
    }

    let images: [ImageEntry]
    let icons: [IconEntry]
    let fonts: [FontEntry]

    private enum CodingKeys: String, CodingKey {
        case images, icons, fonts
    }

    init(images: [ImageEntry] = [], icons: [IconEntry] = [], fonts: [FontEntry] = []) {
        self.images = images
        self.icons = icons
        self.fonts = fonts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        images = try container.decodeIfPresent([ImageEntry].self, forKey: .images) ?? []
        icons = try container.decodeIfPresent([IconEntry].self, forKey: .icons) ?? []
        fonts = try container.decodeIfPresent([FontEntry].self, forKey: .fonts) ?? []
    }
}

// MARK: - Bundled Flow Assets

/// Declares where a bundled flow's offline image/font files live, so the SDK can
/// seed its image cache and register custom fonts before presentation.
///
/// The recommended layout is an exported `.flowassets` folder dropped into the
/// app target:
/// ```
/// OnboardingDefault.flowassets/
///   flow.json
///   manifest.json
///   images/<file>.png
///   fonts/<family-weight>.ttf
/// ```
/// Point this at that folder (via `Bundle` + subdirectory) or, in tests, at a
/// plain filesystem directory.
public struct BundledFlowAssets: @unchecked Sendable {
    enum Location {
        /// A plain filesystem directory (folder resolved at runtime, or tests).
        case directory(URL)
        /// An app bundle, optionally narrowed to a subdirectory (folder reference).
        case bundle(Bundle, subdirectory: String?)
    }

    let location: Location
    /// Base name of the manifest JSON resource (without extension), default "manifest".
    let manifestName: String

    /// Assets in a plain filesystem directory containing the manifest + files.
    public init(directoryURL: URL, manifest: String = "manifest") {
        self.location = .directory(directoryURL)
        self.manifestName = manifest
    }

    /// Assets in an app bundle, optionally inside a subdirectory (folder reference),
    /// e.g. `subdirectory: "OnboardingDefault.flowassets"`.
    public init(bundle: Bundle = .main, subdirectory: String? = nil, manifest: String = "manifest") {
        self.location = .bundle(bundle, subdirectory: subdirectory)
        self.manifestName = manifest
    }

    /// The directory that contains the manifest and the referenced asset files.
    func baseDirectoryURL() -> URL? {
        switch location {
        case .directory(let url):
            return url
        case .bundle(let bundle, let subdirectory):
            guard let resourceURL = bundle.resourceURL else { return nil }
            if let sub = subdirectory, !sub.isEmpty {
                return resourceURL.appendingPathComponent(sub, isDirectory: true)
            }
            return resourceURL
        }
    }

    /// Resolve a manifest `resource` path to a concrete file URL.
    func fileURL(forResource relativePath: String) -> URL? {
        guard let base = baseDirectoryURL() else { return nil }
        return base.appendingPathComponent(relativePath)
    }

    /// Load and decode the sidecar manifest, or `nil` if absent/unreadable/malformed.
    func loadManifest() -> BundledAssetManifest? {
        guard let base = baseDirectoryURL() else { return nil }
        let manifestURL = base.appendingPathComponent("\(manifestName).json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            Logger.shared.debug("BundledFlowAssets: no manifest at \(manifestURL.path)")
            return nil
        }
        do {
            return try JSONDecoder().decode(BundledAssetManifest.self, from: data)
        } catch {
            Logger.shared.warn("BundledFlowAssets: failed to decode manifest at \(manifestURL.path): \(error)")
            return nil
        }
    }
}

// MARK: - Bundled Asset Seeder

/// Seeds the SDK's image and font caches from a bundled flow's local assets,
/// making a Tier-3 (offline) default flow fully self-contained.
///
/// Best-effort by contract: every step is wrapped so a missing/corrupt asset is
/// logged and skipped. It never throws and degrades to today's behaviour (blank
/// image / system font), never a crash or a hang. Run it (awaited) only on the
/// bundled tier, before first paint.
enum BundledAssetSeeder {
    /// Seed both fonts and images for a bundled flow. Fonts are registered first
    /// so the subsequent CDN font-load pass (`FlowPilot.loadFonts`) finds them
    /// already registered and skips the network entirely.
    static func seed(flow: ResolvedFlow, assets: BundledFlowAssets) async {
        guard let manifest = assets.loadManifest() else {
            Logger.shared.debug("BundledAssetSeeder: no manifest for flow \(flow.flowId); nothing to seed")
            return
        }

        seedFonts(flow: flow, assets: assets, manifest: manifest)
        seedIcons(flow: flow, assets: assets, manifest: manifest)

        #if canImport(UIKit)
        await seedImages(flow: flow, assets: assets, manifest: manifest)
        #endif
    }

    // MARK: Icons

    static func seedIcons(flow: ResolvedFlow, assets: BundledFlowAssets, manifest: BundledAssetManifest) {
        guard !manifest.icons.isEmpty else { return }

        var seeded = 0
        for entry in manifest.icons {
            let resolved: URL?
            if let urlString = entry.url, let url = URL(string: urlString) {
                resolved = url
            } else {
                resolved = IconURLResolver.resolve(name: entry.name, iconBaseUrl: flow.iconBaseUrl)
            }
            guard let resolvedURL = resolved,
                  let fileURL = assets.fileURL(forResource: entry.resource) else { continue }
            if IconCache.shared.hasData(for: resolvedURL) { continue }
            guard let data = try? Data(contentsOf: fileURL) else {
                Logger.shared.warn("BundledAssetSeeder: could not read bundled icon at \(fileURL.path)")
                continue
            }
            // Raw SVG bytes, keyed by the same URL the renderer fetches.
            IconCache.shared.setData(data, for: resolvedURL)
            seeded += 1
        }

        Logger.shared.info("BundledAssetSeeder: seeded \(seeded) bundled icon(s) for flow \(flow.flowId)")
    }

    // MARK: Fonts

    static func seedFonts(flow: ResolvedFlow, assets: BundledFlowAssets, manifest: BundledAssetManifest) {
        guard !manifest.fonts.isEmpty else { return }

        var registered = 0
        for entry in manifest.fonts {
            guard let fileURL = assets.fileURL(forResource: entry.resource) else { continue }
            let font = FontFile(
                family: entry.family,
                weight: entry.weight,
                style: entry.style ?? "normal",
                url: fileURL.absoluteString
            )
            // registerLocalFont is itself non-fatal (missing file / bad font logged).
            FontManager.shared.registerLocalFont(font, fileURL: fileURL)
            registered += 1
        }

        Logger.shared.info("BundledAssetSeeder: processed \(registered) bundled font(s) for flow \(flow.flowId)")
    }

    // MARK: Images

    #if canImport(UIKit)
    static func seedImages(flow: ResolvedFlow, assets: BundledFlowAssets, manifest: BundledAssetManifest) async {
        guard !manifest.images.isEmpty else { return }

        // Build resolved-URL -> local-file map. Resolving through MediaURLResolver
        // (for `src` entries) guarantees the seed key equals the render key.
        var fileByURL: [URL: URL] = [:]
        for entry in manifest.images {
            let resolved: URL?
            if let urlString = entry.url, let url = URL(string: urlString) {
                resolved = url
            } else {
                resolved = MediaURLResolver.resolve(src: entry.src, mediaBaseUrl: flow.mediaBaseUrl)
            }
            guard let resolvedURL = resolved,
                  let fileURL = assets.fileURL(forResource: entry.resource) else { continue }
            fileByURL[resolvedURL] = fileURL
        }

        var seeded = 0
        for (resolvedURL, fileURL) in fileByURL {
            if ImageCache.shared.hasImage(for: resolvedURL) { continue }
            guard let data = try? Data(contentsOf: fileURL) else {
                Logger.shared.warn("BundledAssetSeeder: could not read bundled image at \(fileURL.path)")
                continue
            }
            // setImageData populates the in-memory layer synchronously, so the
            // first paint hits the cache even though the disk write is async.
            ImageCache.shared.setImageData(data, for: resolvedURL, ttl: ImageCache.bundledAssetTTL)
            seeded += 1
        }

        // Surface referenced images we couldn't seed, so an incomplete export is
        // visible in logs rather than silently rendering a blank/network image.
        let referenced = FlowAssetEnumerator.imageURLs(in: flow)
        let missing = referenced.filter { fileByURL[$0] == nil && !ImageCache.shared.hasImage(for: $0) }
        if !missing.isEmpty {
            Logger.shared.warn("BundledAssetSeeder: \(missing.count) referenced image(s) have no bundled asset for flow \(flow.flowId) — they will load from network / show blank offline")
        }

        Logger.shared.info("BundledAssetSeeder: seeded \(seeded) bundled image(s) for flow \(flow.flowId)")
    }
    #endif
}
