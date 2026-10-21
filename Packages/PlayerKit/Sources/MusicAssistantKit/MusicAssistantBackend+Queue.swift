import Foundation
import MusicBackendKit

/// The playlist editor's view of a Music Assistant queue (#0144).
extension MusicAssistantBackend {
    struct QueueWatcher {
        var output: OutputDevice.ID
        var continuation: AsyncStream<RemoteQueueSnapshot>.Continuation
        var task: Task<Void, Never>?
    }

    /// The queue playing on `output` (This Mac: the player wrapping SkinAmp's Sendspin client; a synced speaker: its
    /// leader's queue). Empty while not connected; `connect()` and `disconnect()` restart or empty the stream without
    /// ending it.
    public func queue(on output: OutputDevice.ID) async -> AsyncStream<RemoteQueueSnapshot> {
        let (stream, continuation) = AsyncStream<RemoteQueueSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        queueWatchers[id] = QueueWatcher(output: output, continuation: continuation, task: nil)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeQueueWatcher(id) }
        }
        startQueueWatcher(id)
        return stream
    }

    public func edit(_ edit: QueueEdit, on output: OutputDevice.ID) async throws {
        try await guarded {
            let client = try requireClient()
            let queueID = try await queueID(for: output, client: client)
            switch edit {
            case .play(let index):
                _ = try await client.call(.queuePlayIndex(queueID: queueID, index: index))
            }
        }
    }

    /// For tests: smaller pages and caps. Applies to watches started afterwards.
    func setQueuePolicy(_ policy: MAQueuePolicy) { queuePolicy = policy }

    private func removeQueueWatcher(_ id: UUID) {
        queueWatchers.removeValue(forKey: id)?.task?.cancel()
    }

    private func startQueueWatcher(_ id: UUID) {
        guard var watcher = queueWatchers[id] else { return }
        watcher.task?.cancel()
        watcher.task = nil
        guard let client else {
            queueWatchers[id] = watcher
            watcher.continuation.yield(.empty(on: watcher.output))
            return
        }
        let output = watcher.output
        let watch = MAQueueWatch(
            client: client, output: output, clock: clock, policy: queuePolicy,
            resolveQueueID: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.queueID(for: output, client: client)
            },
            yield: { [continuation = watcher.continuation] in continuation.yield($0) })
        watcher.task = Task { await watch.run() }
        queueWatchers[id] = watcher
    }

    func restartQueueWatchers() {
        for id in queueWatchers.keys { startQueueWatcher(id) }
    }

    func stopQueueWatchers() {
        for (id, var watcher) in queueWatchers {
            watcher.task?.cancel()
            watcher.task = nil
            queueWatchers[id] = watcher
            watcher.continuation.yield(.empty(on: watcher.output))
        }
    }
}
