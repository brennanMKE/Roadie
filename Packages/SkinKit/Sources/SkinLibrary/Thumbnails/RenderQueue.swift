import Foundation

/// A counting gate that hands its slots to the newest waiter first (largest sequence number), so during a fast
/// scroll the most recent requests, the cells on screen, are served before the ones scrolled past. Internal.
final class RenderQueue: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private let limit: Int
    private var running = 0
    private var waiters: [Waiter] = []

    init(limit: Int) { self.limit = max(1, limit) }

    var counts: (running: Int, queued: Int) { lock.withLock { (running, waiters.count) } }

    /// Waits for a slot. `id` orders waiters (higher = newer = first). Throws `CancellationError` when the task is
    /// cancelled before it gets a slot; a cancelled waiter never holds one.
    func acquire(id: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                // Checked under the lock after registration order is fixed: a cancel that fired before this point
                // is seen here; one that fires after finds the waiter below.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if running < limit {
                    running += 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiter: Waiter? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func release() {
        let next: Waiter? = lock.withLock {
            guard let index = waiters.indices.max(by: { waiters[$0].id < waiters[$1].id }) else {
                running -= 1
                return nil
            }
            return waiters.remove(at: index)  // the slot passes straight to the newest waiter
        }
        next?.continuation.resume()
    }
}
