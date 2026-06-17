import Foundation

// MARK: - Disk Cache

/// Persistent disk cache for flow data
final class DiskCache: @unchecked Sendable {
    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "io.flowpilot.diskcache", qos: .utility)

    init(directory: String? = nil) {
        if let customDir = directory {
            self.cacheDirectory = URL(fileURLWithPath: customDir)
        } else {
            let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            self.cacheDirectory = paths[0].appendingPathComponent("FlowPilot", isDirectory: true)
        }

        // Create directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func get<T: Codable>(_ key: String) -> CachedItem<T>? {
        let fileURL = fileURL(for: key)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let wrapper = try decoder.decode(CacheWrapper<T>.self, from: data)

            if wrapper.isExpired {
                try? fileManager.removeItem(at: fileURL)
                return nil
            }

            return CachedItem(value: wrapper.value, expiresAt: wrapper.expiresAt, etag: wrapper.etag)
        } catch {
            Logger.shared.warn("Failed to read cache for \(key): \(error)")
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    /// Read a cached item **ignoring** its freshness TTL, and without deleting
    /// it on expiry. This is what powers "serve the last good flow from cache"
    /// when the network is down: the freshness window says when a flow is fresh
    /// enough to use without a network round-trip, but an expired entry is still
    /// the best fallback we have, so it must survive until a successful resolve
    /// overwrites it. The returned `CachedItem.isExpired` lets callers decide
    /// whether to treat the hit as fresh.
    func getAllowingStale<T: Codable>(_ key: String) -> CachedItem<T>? {
        let fileURL = fileURL(for: key)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let wrapper = try decoder.decode(CacheWrapper<T>.self, from: data)
            return CachedItem(value: wrapper.value, expiresAt: wrapper.expiresAt, etag: wrapper.etag)
        } catch {
            Logger.shared.warn("Failed to read cache (stale-allowed) for \(key): \(error)")
            // Only remove on genuine corruption — not on expiry.
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    func set<T: Codable>(_ key: String, value: T, ttl: TimeInterval, etag: String? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let wrapper = CacheWrapper(
                value: value,
                expiresAt: Date().addingTimeInterval(ttl),
                etag: etag
            )

            do {
                let data = try self.encoder.encode(wrapper)
                let fileURL = self.fileURL(for: key)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Logger.shared.warn("Failed to write cache for \(key): \(error)")
            }
        }
    }

    func remove(_ key: String) {
        let fileURL = fileURL(for: key)
        try? fileManager.removeItem(at: fileURL)
    }

    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }

            do {
                let contents = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    try? self.fileManager.removeItem(at: fileURL)
                }
            } catch {
                Logger.shared.warn("Failed to clear cache: \(error)")
            }
        }
    }

    func cleanExpired() {
        queue.async { [weak self] in
            guard let self = self else { return }

            do {
                let contents = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    if let data = try? Data(contentsOf: fileURL),
                       let wrapper = try? self.decoder.decode(CacheMetadata.self, from: data),
                       wrapper.isExpired {
                        try? self.fileManager.removeItem(at: fileURL)
                    }
                }
            } catch {
                Logger.shared.warn("Failed to clean expired cache: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func fileURL(for key: String) -> URL {
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return cacheDirectory.appendingPathComponent(safeKey + ".json")
    }
}

// MARK: - Cache Wrapper

struct CacheWrapper<T: Codable>: Codable {
    let value: T
    let expiresAt: Date
    let etag: String?

    var isExpired: Bool {
        return Date() > expiresAt
    }
}

struct CacheMetadata: Codable {
    let expiresAt: Date

    var isExpired: Bool {
        return Date() > expiresAt
    }
}

// MARK: - Cached Item

struct CachedItem<T> {
    let value: T
    let expiresAt: Date
    let etag: String?

    var isExpired: Bool {
        return Date() > expiresAt
    }

    var ttlRemaining: TimeInterval {
        return max(0, expiresAt.timeIntervalSince(Date()))
    }
}
