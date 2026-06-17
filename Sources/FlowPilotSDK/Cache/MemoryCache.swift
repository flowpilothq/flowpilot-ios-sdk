import Foundation

// MARK: - Memory Cache

/// In-memory cache with TTL support
final class MemoryCache<T>: @unchecked Sendable {
    private var storage: [String: CacheEntry<T>] = [:]
    private let lock = NSLock()
    private let maxSize: Int

    struct CacheEntry<V> {
        let value: V
        let expiresAt: Date

        var isExpired: Bool {
            return Date() > expiresAt
        }
    }

    init(maxSize: Int = 100) {
        self.maxSize = maxSize
    }

    // MARK: - Public API

    func get(_ key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = storage[key] else {
            return nil
        }

        if entry.isExpired {
            storage.removeValue(forKey: key)
            return nil
        }

        return entry.value
    }

    /// Like `get`, but also returns how much of the entry's TTL remains (seconds).
    /// Lets callers implement stale-while-revalidate — decide whether a still-fresh
    /// entry is close enough to expiry to refresh in the background. Returns nil
    /// when the entry is missing or already expired.
    func getWithRemaining(_ key: String) -> (value: T, remaining: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = storage[key] else {
            return nil
        }

        if entry.isExpired {
            storage.removeValue(forKey: key)
            return nil
        }

        return (entry.value, entry.expiresAt.timeIntervalSinceNow)
    }

    func set(_ key: String, value: T, ttl: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        // Evict if over capacity
        if storage.count >= maxSize {
            evictExpired()

            // If still over capacity, remove oldest
            if storage.count >= maxSize {
                evictOldest()
            }
        }

        let entry = CacheEntry(value: value, expiresAt: Date().addingTimeInterval(ttl))
        storage[key] = entry
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }

        storage.removeValue(forKey: key)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        storage.removeAll()
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = storage[key] else {
            return false
        }

        return !entry.isExpired
    }

    // MARK: - Eviction

    private func evictExpired() {
        let now = Date()
        storage = storage.filter { _, entry in
            entry.expiresAt > now
        }
    }

    private func evictOldest() {
        guard let oldest = storage.min(by: { $0.value.expiresAt < $1.value.expiresAt }) else {
            return
        }
        storage.removeValue(forKey: oldest.key)
    }
}
