import Foundation

// MARK: - Media URL Resolver

/// Single source of truth for turning an image component's `src` (plus the
/// flow's `mediaBaseUrl`) into the concrete `URL` used everywhere downstream.
///
/// The rendering path (`ImageView`), the preloader (`MediaPreloader`), and the
/// offline asset seeder (`BundledAssetSeeder`) all resolve the same way, so the
/// `URL` used to seed the cache is byte-for-byte the `URL` used as the cache
/// lookup key at render time. If these ever drifted, a seeded bundled image
/// would silently miss the cache and fall back to a blank/network load.
enum MediaURLResolver {
    /// Resolve an image `src` against an optional `mediaBaseUrl`.
    ///
    /// - `http(s)://…` absolute sources are used verbatim.
    /// - `data:` sources return `nil` (not cacheable by URL).
    /// - relative sources are joined to `mediaBaseUrl` (tolerating a trailing
    ///   slash on the base), or used as-is when no base is provided.
    /// - empty / `nil` sources return `nil`.
    static func resolve(src: String?, mediaBaseUrl: String?) -> URL? {
        guard let src = src, !src.isEmpty else { return nil }

        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            return URL(string: src)
        }

        // Base64 data URLs aren't backed by a fetchable/cacheable URL.
        if src.hasPrefix("data:") {
            return nil
        }

        if let baseUrl = mediaBaseUrl {
            let fullPath = baseUrl.hasSuffix("/") ? "\(baseUrl)\(src)" : "\(baseUrl)/\(src)"
            return URL(string: fullPath)
        }

        return URL(string: src)
    }
}
