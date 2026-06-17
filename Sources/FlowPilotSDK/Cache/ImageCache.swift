import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
import CommonCrypto

// MARK: - Image Cache

/// Thread-safe image cache with memory and disk layers
public final class ImageCache: @unchecked Sendable {

    // MARK: - Singleton

    /// Shared instance for global image caching
    public static let shared = ImageCache()

    /// TTL used when seeding bundled (offline) assets shipped in the app bundle.
    /// Effectively non-expiring (~100 years) so a build-time default flow's
    /// images never silently fall out of cache between launches. `clearAll()` /
    /// `FlowPilot.clearImageCache()` still removes them on demand.
    public static let bundledAssetTTL: TimeInterval = 100 * 365 * 24 * 60 * 60

    // MARK: - Properties

    private let memoryCache: NSCache<NSString, ImageCacheEntry>
    private let diskCacheDirectory: URL
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "io.flowpilot.imagecache", qos: .utility)
    private let lock = NSLock()

    /// Maximum memory cache size in bytes (default: 50MB)
    public var maxMemoryCacheSize: Int = 50 * 1024 * 1024 {
        didSet {
            memoryCache.totalCostLimit = maxMemoryCacheSize
        }
    }

    /// Maximum disk cache size in bytes (default: 200MB)
    public var maxDiskCacheSize: Int = 200 * 1024 * 1024

    /// Default TTL for cached images (default: 7 days)
    public var defaultTTL: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Initialization

    public init(cacheDirectory: String? = nil) {
        self.memoryCache = NSCache<NSString, ImageCacheEntry>()

        if let customDir = cacheDirectory {
            self.diskCacheDirectory = URL(fileURLWithPath: customDir)
        } else {
            let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            self.diskCacheDirectory = paths[0].appendingPathComponent("FlowPilot/Images", isDirectory: true)
        }

        // Configure memory cache
        memoryCache.totalCostLimit = maxMemoryCacheSize
        memoryCache.countLimit = 100

        // Create directory if needed
        try? fileManager.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)

        // Clean expired on init (async)
        ioQueue.async { [weak self] in
            self?.cleanExpiredFromDisk()
        }
    }

    // MARK: - Public API

    /// Get an image from cache (memory first, then disk)
    public func getImage(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)

        // Check memory cache first
        if let entry = memoryCache.object(forKey: key as NSString) {
            if !entry.isExpired {
                Logger.shared.verbose("ImageCache: Memory hit for \(url.lastPathComponent)")
                return entry.image
            } else {
                memoryCache.removeObject(forKey: key as NSString)
            }
        }

        // Check disk cache
        if let image = loadFromDisk(key: key) {
            // Promote to memory cache
            let entry = ImageCacheEntry(image: image, expiresAt: Date().addingTimeInterval(defaultTTL))
            let cost = estimateImageSize(image)
            memoryCache.setObject(entry, forKey: key as NSString, cost: cost)
            Logger.shared.verbose("ImageCache: Disk hit for \(url.lastPathComponent)")
            return image
        }

        Logger.shared.verbose("ImageCache: Cache miss for \(url.lastPathComponent)")
        return nil
    }

    /// Check if an image is cached (memory or disk)
    public func hasImage(for url: URL) -> Bool {
        let key = cacheKey(for: url)

        // Check memory
        if let entry = memoryCache.object(forKey: key as NSString), !entry.isExpired {
            return true
        }

        // Check disk
        let fileURL = diskFileURL(for: key)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Store an image in cache (both memory and disk)
    public func setImage(_ image: UIImage, for url: URL, ttl: TimeInterval? = nil) {
        let key = cacheKey(for: url)
        let effectiveTTL = ttl ?? defaultTTL
        let expiresAt = Date().addingTimeInterval(effectiveTTL)

        // Store in memory
        let entry = ImageCacheEntry(image: image, expiresAt: expiresAt)
        let cost = estimateImageSize(image)
        memoryCache.setObject(entry, forKey: key as NSString, cost: cost)

        // Store on disk asynchronously
        ioQueue.async { [weak self] in
            self?.saveToDisk(image: image, key: key, expiresAt: expiresAt)
        }

        Logger.shared.verbose("ImageCache: Cached image for \(url.lastPathComponent)")
    }

    /// Store image data directly (useful when downloading)
    public func setImageData(_ data: Data, for url: URL, ttl: TimeInterval? = nil) {
        guard let image = UIImage(data: data) else {
            Logger.shared.warn("ImageCache: Failed to create image from data for \(url)")
            return
        }
        setImage(image, for: url, ttl: ttl)
    }

    /// Remove a specific image from cache
    public func removeImage(for url: URL) {
        let key = cacheKey(for: url)

        memoryCache.removeObject(forKey: key as NSString)

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.diskFileURL(for: key)
            try? self.fileManager.removeItem(at: fileURL)
        }
    }

    /// Clear all cached images
    public func clearAll() {
        memoryCache.removeAllObjects()

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let contents = try self.fileManager.contentsOfDirectory(at: self.diskCacheDirectory, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    try? self.fileManager.removeItem(at: fileURL)
                }
                Logger.shared.info("ImageCache: Cleared all cached images")
            } catch {
                Logger.shared.warn("ImageCache: Failed to clear disk cache: \(error)")
            }
        }
    }

    /// Clean expired entries from disk
    public func cleanExpired() {
        ioQueue.async { [weak self] in
            self?.cleanExpiredFromDisk()
        }
    }

    // MARK: - Disk Operations

    private func saveToDisk(image: UIImage, key: String, expiresAt: Date) {
        // Always save as PNG to preserve transparency
        // PNG is lossless and supports alpha channel
        guard let data = image.pngData() else {
            // Fallback to JPEG only if PNG fails (rare)
            guard let jpegData = image.jpegData(compressionQuality: 0.9) else {
                return
            }
            saveDataToDisk(jpegData, key: key, expiresAt: expiresAt)
            return
        }

        saveDataToDisk(data, key: key, expiresAt: expiresAt)
    }

    private func saveDataToDisk(_ data: Data, key: String, expiresAt: Date) {
        let fileURL = diskFileURL(for: key)
        let metadataURL = diskMetadataURL(for: key)

        do {
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)

            // Save metadata with expiration
            let metadata = ImageCacheMetadata(expiresAt: expiresAt)
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: metadataURL, options: Data.WritingOptions.atomic)
        } catch {
            Logger.shared.warn("ImageCache: Failed to save to disk: \(error)")
        }
    }

    private func loadFromDisk(key: String) -> UIImage? {
        let fileURL = diskFileURL(for: key)
        let metadataURL = diskMetadataURL(for: key)

        // Check if file exists
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Check expiration
        if let metadataData = try? Data(contentsOf: metadataURL),
           let metadata = try? JSONDecoder().decode(ImageCacheMetadata.self, from: metadataData) {
            if metadata.isExpired {
                // Clean up expired files
                try? fileManager.removeItem(at: fileURL)
                try? fileManager.removeItem(at: metadataURL)
                return nil
            }
        }

        // Load image
        guard let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }

        return image
    }

    private func cleanExpiredFromDisk() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: diskCacheDirectory, includingPropertiesForKeys: nil)

            for fileURL in contents where fileURL.pathExtension == "meta" {
                if let data = try? Data(contentsOf: fileURL),
                   let metadata = try? JSONDecoder().decode(ImageCacheMetadata.self, from: data),
                   metadata.isExpired {
                    // Remove both metadata and image files
                    try? fileManager.removeItem(at: fileURL)
                    let imageURL = fileURL.deletingPathExtension()
                    try? fileManager.removeItem(at: imageURL)
                }
            }
        } catch {
            Logger.shared.warn("ImageCache: Failed to clean expired: \(error)")
        }
    }

    // MARK: - Helpers

    private func cacheKey(for url: URL) -> String {
        // Use SHA256 hash of URL for safe file naming
        let urlString = url.absoluteString
        return urlString.sha256Hash
    }

    private func diskFileURL(for key: String) -> URL {
        return diskCacheDirectory.appendingPathComponent(key)
    }

    private func diskMetadataURL(for key: String) -> URL {
        return diskCacheDirectory.appendingPathComponent(key + ".meta")
    }

    private func estimateImageSize(_ image: UIImage) -> Int {
        // Estimate memory size based on dimensions
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        let bytesPerPixel = 4 // 4 bytes per pixel (RGBA)
        return width * height * bytesPerPixel
    }
}

// MARK: - Cache Entry

private final class ImageCacheEntry {
    let image: UIImage
    let expiresAt: Date

    var isExpired: Bool {
        return Date() > expiresAt
    }

    init(image: UIImage, expiresAt: Date) {
        self.image = image
        self.expiresAt = expiresAt
    }
}

// MARK: - Cache Metadata

private struct ImageCacheMetadata: Codable {
    let expiresAt: Date

    var isExpired: Bool {
        return Date() > expiresAt
    }
}

// MARK: - String Extension for Hashing

extension String {
    var sha256Hash: String {
        guard let data = self.data(using: .utf8) else { return self }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

#else

// MARK: - Stub for non-UIKit platforms

/// Stub ImageCache for non-UIKit platforms
public final class ImageCache: @unchecked Sendable {
    public static let shared = ImageCache()
    public static let bundledAssetTTL: TimeInterval = 100 * 365 * 24 * 60 * 60
    public var maxMemoryCacheSize: Int = 50 * 1024 * 1024
    public var maxDiskCacheSize: Int = 200 * 1024 * 1024
    public var defaultTTL: TimeInterval = 7 * 24 * 60 * 60

    public init(cacheDirectory: String? = nil) {}
    public func hasImage(for url: URL) -> Bool { return false }
    public func clearAll() {}
    public func cleanExpired() {}
    public func removeImage(for url: URL) {}
}

#endif
