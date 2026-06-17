import Foundation

// MARK: - Font Manifest

/// Represents a font file delivered by the backend for custom font rendering.
/// The backend extracts font requirements from the flow schema and provides
/// CDN URLs for each required family+weight combination.
public struct FontFile: Codable, Sendable, Hashable {
    /// Font family name (e.g., "Inter", "Poppins")
    public let family: String

    /// Font weight (100-900)
    public let weight: Int

    /// Font style (e.g., "normal", "italic")
    public let style: String

    /// Full CDN URL to the .ttf file
    public let url: String

    /// Cache key for deduplication and disk cache
    var cacheKey: String {
        "\(family)-\(weight)"
    }
}
