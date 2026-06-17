import Foundation

// MARK: - Analytics Batcher

/// Batches analytics events for efficient sending
final class AnalyticsBatcher: @unchecked Sendable {
    // Configuration per spec
    private let batchSize = 10
    private let flushIntervalMs: UInt64 = 30_000 // 30 seconds
    private let maxQueueSize = 100
    private let requestTimeoutMs: UInt64 = 10_000

    // State
    private var queue: [AnalyticsEvent] = []
    private var retryCount = 0
    private var flushTask: Task<Void, Never>?
    private let lock = NSLock()

    // Dependencies
    private let eventService: EventService?
    private let persistenceQueue = DispatchQueue(label: "io.flowpilot.analytics.persistence")

    // Persistence
    private let persistenceKey = "io.flowpilot.pending_events"

    init(eventService: EventService?) {
        self.eventService = eventService
        loadPersistedEvents()
        startFlushTimer()
    }

    deinit {
        flushTask?.cancel()
    }

    // MARK: - Public API

    func enqueue(_ event: AnalyticsEvent) {
        lock.lock()

        // Enforce max queue size
        if queue.count >= maxQueueSize {
            queue.removeFirst()
            Logger.shared.warn("Analytics queue full, dropping oldest event")
        }

        queue.append(event)
        let shouldFlush = queue.count >= batchSize
        lock.unlock()

        // Check if batch is full
        if shouldFlush {
            Task {
                await flush()
            }
        }
    }

    func flush() async {
        lock.lock()
        guard !queue.isEmpty else {
            lock.unlock()
            return
        }

        // Take up to batchSize events
        let batchCount = min(batchSize, queue.count)
        let batch = Array(queue.prefix(batchCount))
        queue.removeFirst(batchCount)
        lock.unlock()

        do {
            try await sendBatch(batch)
            retryCount = 0
            persistQueue()
        } catch let error as FlowPilotError {
            // Check if this is a client error (4xx) - these should NOT be retried
            // because the request format is wrong and retrying won't fix it
            if error.isClientError {
                Logger.shared.warn("Dropping \(batch.count) events due to client error (will not retry): \(error)")
                // Don't put events back - they're malformed and will never succeed
                retryCount = 0
                persistQueue()
            } else {
                // Server error or network issue - retry with backoff
                lock.lock()
                queue.insert(contentsOf: batch, at: 0)
                lock.unlock()

                Logger.shared.warn("Failed to send events (will retry): \(error)")
                scheduleRetry()
            }
        } catch {
            // Unknown error - retry
            lock.lock()
            queue.insert(contentsOf: batch, at: 0)
            lock.unlock()

            Logger.shared.warn("Failed to send events: \(error)")
            scheduleRetry()
        }
    }

    // MARK: - Sending

    private func sendBatch(_ batch: [AnalyticsEvent]) async throws {
        guard let eventService = eventService else {
            Logger.shared.debug("No event service, skipping batch of \(batch.count) events")
            return
        }

        Logger.shared.debug("Sending batch of \(batch.count) events")

        _ = try await withThrowingTaskGroup(of: EventResponse.self) { group in
            group.addTask {
                try await eventService.sendEvents(batch)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: self.requestTimeoutMs * 1_000_000)
                throw FlowPilotError.timeout()
            }

            return try await group.next()!
        }
    }

    // MARK: - Timer

    private func startFlushTimer() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.flushIntervalMs ?? 30_000 * 1_000_000)
                await self?.flush()
            }
        }
    }

    // MARK: - Retry

    private func scheduleRetry() {
        let delay = calculateRetryDelay()
        retryCount += 1

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await flush()
        }
    }

    private func calculateRetryDelay() -> TimeInterval {
        // Exponential backoff: 1, 2, 4, 8, 16... capped at 60
        let baseDelay = 1.0
        let maxDelay = 60.0
        let delay = min(pow(2.0, Double(retryCount)) * baseDelay, maxDelay)
        return delay
    }

    // MARK: - Persistence

    private func loadPersistedEvents() {
        persistenceQueue.async { [weak self] in
            guard let self = self,
                  let data = UserDefaults.standard.data(forKey: self.persistenceKey),
                  let events = try? JSONDecoder().decode([AnalyticsEvent].self, from: data) else {
                return
            }

            self.lock.lock()
            // Prepend persisted events
            self.queue.insert(contentsOf: events, at: 0)
            // Enforce max size
            if self.queue.count > self.maxQueueSize {
                self.queue = Array(self.queue.suffix(self.maxQueueSize))
            }
            self.lock.unlock()

            Logger.shared.debug("Loaded \(events.count) persisted events")

            // Clear persistence
            UserDefaults.standard.removeObject(forKey: self.persistenceKey)
        }
    }

    private func persistQueue() {
        lock.lock()
        let events = queue
        lock.unlock()

        guard !events.isEmpty else {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            return
        }

        persistenceQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                let data = try JSONEncoder().encode(events)
                UserDefaults.standard.set(data, forKey: self.persistenceKey)
            } catch {
                Logger.shared.warn("Failed to persist events: \(error)")
            }
        }
    }
}
