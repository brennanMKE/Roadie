import Foundation
import MusicBackendKit

/// Turns Music Assistant's pushed events into `LibraryChange`s (#0139, design §1.4 and §3.3). Lenient on purpose:
/// the envelopes are unverified (#0076), so the item's URI comes from `object_id`, else `data.uri`, and an event
/// that doesn't parse yields nothing rather than failing.
public enum MALibraryChanges {
    public static let eventNames: Set<String> = [
        "media_item_added", "media_item_updated", "media_item_deleted", "media_item_played", "favorite_updated",
    ]

    public static func classify(_ event: MAServerEvent) -> [LibraryChange] {
        guard eventNames.contains(event.event) else { return [] }
        if event.event == "media_item_played" { return [.played] }
        guard let uri = uri(of: event) else { return [] }
        let id = MediaID(uri.mediaType.mediaKind, uri.string)
        let favorite = event.data["favorite"]?.boolValue
        switch event.event {
        case "favorite_updated":
            return [.favoriteChanged(id, favorite)]
        case "media_item_added":
            var changes: [LibraryChange] = uri.mediaType == .playlist ? [.playlistAdded(id)] : []
            if favorite == true { changes.append(.favoriteChanged(id, true)) }
            return changes
        case "media_item_updated":
            var changes: [LibraryChange] = uri.mediaType == .playlist ? [.playlistUpdated(id)] : []
            // 2.10.6 has no `favorite_updated`: the item's own `favorite` stands in for it.
            if let favorite { changes.append(.favoriteChanged(id, favorite)) }
            return changes
        case "media_item_deleted":
            return uri.mediaType == .playlist ? [.playlistDeleted(id)] : []
        default:
            return []
        }
    }

    static func uri(of event: MAServerEvent) -> MAURI? {
        if let objectID = event.objectID, let uri = MAURI.parse(objectID) { return uri }
        if let string = event.data["uri"]?.stringValue, let uri = MAURI.parse(string) { return uri }
        return nil
    }
}

// MARK: Backend plumbing (#0139), like `playbackActivity()`

extension MusicAssistantBackend {
    /// Playlist and favorite changes made anywhere, as refetch hints. Silent while disconnected; follows the
    /// installed client across its reconnects and a switch to another client. Runs only while someone subscribes.
    /// `async` like the requirement: a sync overload would lose to the protocol's async default in async contexts.
    public func libraryChanges() async -> AsyncStream<LibraryChange> {
        let (stream, continuation) = AsyncStream<LibraryChange>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        libraryChangeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLibraryChangeContinuation(id) }
        }
        if libraryChangeTask == nil { restartLibraryChanges() }
        return stream
    }

    private func removeLibraryChangeContinuation(_ id: UUID) {
        libraryChangeContinuations[id] = nil
        if libraryChangeContinuations.isEmpty { stopLibraryChanges() }
    }

    /// Called on connect; the client's own event stream survives its reconnects.
    func restartLibraryChanges() {
        stopLibraryChanges()
        guard let client, !libraryChangeContinuations.isEmpty else { return }
        libraryChangeTask = Task { [weak self] in
            for await event in await client.events() {
                guard let self else { return }
                await self.libraryEvent(event, from: client)
            }
        }
    }

    func stopLibraryChanges() {
        libraryChangeTask?.cancel()
        libraryChangeTask = nil
    }

    private func libraryEvent(_ event: MAServerEvent, from source: MusicAssistantClient) {
        guard source === client else { return }
        for change in MALibraryChanges.classify(event) {
            for continuation in libraryChangeContinuations.values { continuation.yield(change) }
        }
    }
}
