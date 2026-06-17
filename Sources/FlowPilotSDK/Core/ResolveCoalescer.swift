import Foundation

// MARK: - Resolve Coalescer

/// Dedupes concurrent network resolves for the same cache key so a prefetch and a
/// present-time resolve (or two prefetches, or N concurrent presents) share a
/// single round-trip instead of each firing their own.
///
/// The shared work is held as an **unstructured** `Task` on purpose: a caller
/// that hits its own deadline and walks away must NOT cancel the shared resolve.
/// It should keep running so it still populates the cache for the next caller.
/// Callers bound their *own* wait via `awaitValue(of:timeout:)`, which abandons
/// the wait at the deadline without touching the shared task.
actor ResolveCoalescer {
    /// In-flight shared resolves, keyed by cache key (`placement:<id>:<fingerprint>`).
    private var inFlight: [String: Task<ResolvedFlow, Error>] = [:]

    /// Returns the in-flight shared resolve for `key`, starting one via
    /// `operation` if none exists. The returned `Task` is unstructured and owned
    /// by this actor; awaiting (or cancelling the awaiter of) its value never
    /// cancels it. The in-flight slot is cleared once the operation finishes, so
    /// the next resolve after completion starts fresh.
    func sharedTask(
        key: String,
        operation: @escaping @Sendable () async throws -> ResolvedFlow
    ) -> Task<ResolvedFlow, Error> {
        if let existing = inFlight[key] {
            return existing
        }
        // Clear the in-flight slot whether the operation succeeds or throws.
        // Done inline (not in a `defer { Task { ... } }`) so we never capture
        // `self` inside a nested concurrent closure — which Swift 5.10 rejects
        // as "reference to captured var 'self' in concurrently-executing code".
        let task = Task { [weak self] () throws -> ResolvedFlow in
            do {
                let flow = try await operation()
                await self?.clear(key: key)
                return flow
            } catch {
                await self?.clear(key: key)
                throw error
            }
        }
        inFlight[key] = task
        return task
    }

    /// Convenience: join (or start) the shared resolve for `key` and await its
    /// value. Used where no per-caller deadline is needed; the present path uses
    /// `sharedTask` + `awaitValue` so it can time out without cancelling the share.
    func resolve(
        key: String,
        operation: @escaping @Sendable () async throws -> ResolvedFlow
    ) async throws -> ResolvedFlow {
        let task = sharedTask(key: key, operation: operation)
        return try await task.value
    }

    /// Number of resolves currently in flight. Test/diagnostic use only.
    var inFlightCount: Int { inFlight.count }

    private func clear(key: String) {
        inFlight[key] = nil
    }
}

// MARK: - Interruptible Await

/// Await `task`'s value, but give up after `timeout` seconds (throwing
/// `FlowPilotError.timeout()`) or if the surrounding task is cancelled (throwing
/// `CancellationError`) — **without** cancelling `task` itself.
///
/// This is the piece that lets a caller honor its own hard deadline while a
/// coalesced/shared resolve keeps running in the background to populate the cache
/// for the next caller. A structured `withThrowingTaskGroup` can't do this:
/// awaiting another `Task`'s `.value` is not interrupted by the awaiter's
/// cancellation, so the group would block on it until the network finishes,
/// silently defeating the timeout. Instead we race two detached deliverers (the
/// shared task's result and a timer) into a single continuation; whichever fires
/// first wins, and the loser is harmlessly abandoned.
func awaitValue<T: Sendable>(of task: Task<T, Error>, timeout: TimeInterval) async throws -> T {
    let gate = ResumeGate<T>()
    let timerBox = CancelBox()
    defer { timerBox.cancel() } // stop the timer once we've resumed
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            gate.set(continuation)

            // Deliver the shared task's result. Awaiting `task.value` here does
            // NOT cancel `task`; if we lose the race this observer simply no-ops.
            Task {
                do { gate.fire(.success(try await task.value)) }
                catch { gate.fire(.failure(error)) }
            }

            // Deliver a timeout after the per-caller deadline.
            let timer = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    gate.fire(.failure(FlowPilotError.timeout()))
                } catch {
                    // Timer itself was cancelled (we already resumed) — ignore.
                }
            }
            timerBox.set(timer)
        }
    } onCancel: {
        // The caller was cancelled: stop waiting, but leave the shared task alone.
        gate.fire(.failure(CancellationError()))
    }
}

// MARK: - Continuation Plumbing

/// Single-shot continuation gate: the first `fire` wins and resumes the
/// continuation exactly once; later fires are ignored. Tolerates a `fire` that
/// arrives before `set` (e.g. an already-cancelled caller) by stashing the
/// result until the continuation is attached.
private final class ResumeGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending = pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func fire(_ result: Result<T, Error>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Thread-safe holder for a cancellable timer task.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock(); self.task = task; lock.unlock()
    }

    func cancel() {
        lock.lock(); let task = self.task; self.task = nil; lock.unlock()
        task?.cancel()
    }
}
