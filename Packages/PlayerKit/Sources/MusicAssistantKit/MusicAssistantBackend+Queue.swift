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
            do {
                let client = try requireClient()
                let queueID = try await queueID(for: output, client: client)
                switch edit {
                case .play(let index):
                    _ = try await client.call(.queuePlayIndex(queueID: queueID, index: index))
                case .remove(let items):
                    for item in items.sorted(by: { $0.index > $1.index }) {
                        _ = try await client.call(.queueDeleteItem(queueID: queueID, itemID: item.id))
                    }
                case .move(let itemID, let shift):
                    guard shift != 0 else { return }
                    _ = try await client.call(.queueMoveItem(queueID: queueID, itemID: itemID, shift: shift))
                case .clear:
                    _ = try await client.call(.queueClear(queueID: queueID))
                }
            } catch MusicAssistantError.server(_, let details) where Self.isBufferedRefusal(details) {
                throw QueueEditError.buffered
            }
        }
    }

    /// `player_queues/save_as_playlist` on the queue `output` plays (a synced speaker: its leader's) (#0140). An empty
    /// queue (`QueueEmpty`, error code 8) is `.backend(emptyQueueText)`; a queue with nothing a playlist can hold
    /// (`InvalidDataError`, code 3, e.g. only radio stations) is `.backend(nothingToSaveText)`.
    public func saveQueueAsPlaylist(on output: OutputDevice.ID, named name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MusicBackendError.backend(Self.playlistNameMissingText) }
        try await guarded {
            do {
                let client = try requireClient()
                let queueID = try await queueID(for: output, client: client)
                _ = try await client.call(.queueSaveAsPlaylist(queueID: queueID, name: name))
            } catch MusicAssistantError.server(let code, let details) where Self.isEmptyQueueRefusal(code: code, details) {
                throw MusicBackendError.backend(Self.emptyQueueText)
            } catch MusicAssistantError.server(code: Self.invalidDataErrorCode, _) {
                throw MusicBackendError.backend(Self.nothingToSaveText)
            }
        }
    }

    public static let emptyQueueText = "The queue is empty: there is nothing to save."
    public static let nothingToSaveText = "Nothing in this queue can go in a playlist."
    public static let playlistNameMissingText = "The playlist needs a name."

    /// `music_assistant_models.errors`: `QueueEmpty.error_code` and `InvalidDataError.error_code`.
    static let queueEmptyErrorCode = 8
    static let invalidDataErrorCode = 3

    /// `save_as_playlist` raises `QueueEmpty("Cannot save an empty queue as a playlist.")`; the server sends its code
    /// (8) and message. The details check is a fallback for a server that sends another code.
    static func isEmptyQueueRefusal(code: Int, _ details: String) -> Bool {
        if code == queueEmptyErrorCode { return true }
        let text = details.lowercased()
        return text.contains("empty queue") || text.contains("queueempty")
    }

    /// Music Assistant raises `IndexError` for a move or delete at or before the buffered index; it arrives as a server
    /// error whose details name it (or say "buffered").
    static func isBufferedRefusal(_ details: String) -> Bool {
        let text = details.lowercased()
        return text.contains("indexerror") || text.contains("buffer")
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

extension MARequest {
    /// Removes one queue item by its `queue_item_id` (#0145).
    public static func queueDeleteItem(queueID: String, itemID: String) -> MARequest {
        MARequest(
            command: "player_queues/delete_item",
            args: ["queue_id": .string(queueID), "item_id_or_index": .string(itemID)])
    }

    /// Moves one queue item `shift` rows; positive moves it down (#0145).
    public static func queueMoveItem(queueID: String, itemID: String, shift: Int) -> MARequest {
        MARequest(
            command: "player_queues/move_item",
            args: ["queue_id": .string(queueID), "queue_item_id": .string(itemID), "pos_shift": .number(Double(shift))])
    }

    /// Saves the queue as a new playlist on the builtin provider (#0140). Returns a `BackgroundTask`.
    public static func queueSaveAsPlaylist(queueID: String, name: String) -> MARequest {
        MARequest(command: "player_queues/save_as_playlist", args: ["queue_id": .string(queueID), "name": .string(name)])
    }

    /// Empties the queue (#0145).
    public static func queueClear(queueID: String) -> MARequest {
        MARequest(command: "player_queues/clear", args: ["queue_id": .string(queueID)])
    }
}
