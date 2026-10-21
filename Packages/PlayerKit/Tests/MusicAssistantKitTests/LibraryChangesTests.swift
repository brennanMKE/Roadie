import Foundation
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// `MALibraryChanges.classify` (#0139): the shapes from design §1.4, unrecorded until #0076.
struct LibraryChangesTests {
    private let playlist4 = MediaID(.playlist, "library://playlist/4")

    @Test func playlistDeletedFromObjectID() {
        let event = MAServerEvent(event: "media_item_deleted", objectID: "library://playlist/4", data: .null)
        #expect(MALibraryChanges.classify(event) == [.playlistDeleted(playlist4)])
    }

    @Test func playlistAddedAndUpdated() {
        let added = MAServerEvent(event: "media_item_added", objectID: "library://playlist/4")
        #expect(MALibraryChanges.classify(added) == [.playlistAdded(playlist4)])
        let updated = MAServerEvent(event: "media_item_updated", objectID: "library://playlist/4")
        #expect(MALibraryChanges.classify(updated) == [.playlistUpdated(playlist4)])
    }

    @Test func favoriteUpdatedIsAFavoriteChange() {
        let event = MAServerEvent(
            event: "favorite_updated", objectID: "library://track/9",
            data: .object([
                "uri": "library://track/9", "media_type": "track", "item_id": "9", "favorite": .bool(true),
            ]))
        #expect(MALibraryChanges.classify(event) == [.favoriteChanged(MediaID(.track, "library://track/9"), true)])
    }

    @Test func mediaItemUpdatedWithFavoriteIsAFavoriteChange() {
        let event = MAServerEvent(
            event: "media_item_updated", objectID: "library://album/3",
            data: .object(["uri": "library://album/3", "favorite": .bool(false)]))
        #expect(MALibraryChanges.classify(event) == [.favoriteChanged(MediaID(.album, "library://album/3"), false)])
    }

    @Test func nonPlaylistURIsAreIgnored() {
        for name in ["media_item_added", "media_item_updated", "media_item_deleted"] {
            #expect(MALibraryChanges.classify(MAServerEvent(event: name, objectID: "library://track/3")) == [])
        }
        #expect(MALibraryChanges.classify(MAServerEvent(event: "media_item_deleted", objectID: "not a uri")) == [])
        #expect(MALibraryChanges.classify(MAServerEvent(event: "queue_updated", objectID: "library://playlist/4")) == [])
    }

    @Test func missingObjectIDFallsBackToDataURI() {
        let event = MAServerEvent(
            event: "media_item_deleted", objectID: nil, data: .object(["uri": "library://playlist/4"]))
        #expect(MALibraryChanges.classify(event) == [.playlistDeleted(playlist4)])
    }

    @Test func playedIsARefreshHint() {
        #expect(MALibraryChanges.classify(MAServerEvent(event: "media_item_played", objectID: "library://track/1")) == [.played])
    }
}

/// `MusicAssistantBackend.libraryChanges()` over the stub socket (#0139).
struct BackendLibraryChangesTests {
    private static func deleted(_ id: Int) -> String {
        MAJSON.object([
            "event": "media_item_deleted", "object_id": .string("library://playlist/\(id)"), "data": .null,
        ]).encodedString()
    }

    @Test func streamRestartsAfterReconnect() async throws {
        let rig = try await connectedBackend()
        let collector = Collector(await rig.backend.libraryChanges())
        let first = LibraryChange.playlistDeleted(MediaID(.playlist, "library://playlist/1"))
        // The subscription starts asynchronously: push until it is seen.
        #expect(await waitFor {
            rig.transport.push(Self.deleted(1))
            try? await Task.sleep(for: .milliseconds(20))
            return collector.items.contains(first)
        })
        let client = try #require(await rig.backend.client)
        rig.transport.closeFromServer()
        #expect(await waitFor {
            if case .reconnecting = await client.state { return true }
            return false
        })
        rig.clock.advance(by: .seconds(2))
        #expect(await waitFor {
            guard rig.factory.transports.count == 2 else { return false }
            if case .connected = await client.state { return true }
            return false
        })
        let second = LibraryChange.playlistDeleted(MediaID(.playlist, "library://playlist/2"))
        #expect(await waitFor {
            rig.factory.transports[1].push(Self.deleted(2))
            try? await Task.sleep(for: .milliseconds(20))
            return collector.items.contains(second)
        })
        collector.stop()
        await rig.backend.disconnect()
    }
}
