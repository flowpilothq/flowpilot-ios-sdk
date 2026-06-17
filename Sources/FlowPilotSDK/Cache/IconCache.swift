import Foundation

// MARK: - Icon Cache

/// In-memory cache of raw Lucide SVG bytes, keyed by the icon's CDN URL.
///
/// Icons are fetched as color-independent SVG source and recolored at draw time
/// (`LucideSVGRenderer`), so the cacheable unit is the raw bytes — not a rendered
/// image. `SVGIconLoader` consults this cache before hitting the network, and the
/// offline seeder (`BundledAssetSeeder.seedIcons`) pre-populates it from bundled
/// `.svg` files so a Tier-3 bundled flow shows real icons offline (instead of the
/// SF Symbol fallback).
///
/// Memory-only by design: the seeder re-populates it from the bundle on every
/// offline presentation, so there's nothing to persist across launches. Tiny
/// payloads (a few KB per glyph).
public final class IconCache: @unchecked Sendable {

    /// Shared instance used by the renderer and the seeder.
    public static let shared = IconCache()

    private let memory = NSCache<NSString, NSData>()

    public init(countLimit: Int = 256) {
        memory.countLimit = countLimit
    }

    private func key(for url: URL) -> NSString { url.absoluteString as NSString }

    /// Cached SVG bytes for an icon URL, if present.
    public func data(for url: URL) -> Data? {
        memory.object(forKey: key(for: url)) as Data?
    }

    /// Whether SVG bytes are cached for an icon URL.
    public func hasData(for url: URL) -> Bool {
        memory.object(forKey: key(for: url)) != nil
    }

    /// Store SVG bytes for an icon URL.
    public func setData(_ data: Data, for url: URL) {
        memory.setObject(data as NSData, forKey: key(for: url), cost: data.count)
    }

    /// Drop all cached icon bytes.
    public func clearAll() {
        memory.removeAllObjects()
    }
}
