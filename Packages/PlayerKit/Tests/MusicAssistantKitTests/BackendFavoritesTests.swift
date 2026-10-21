import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

struct BackendFavoritesTests {
    private func rig() async throws -> BackendRig {
        try await connectedBackend(
            script: controlScript {
                for command in [
                    "music/favorites/add_item", "music/favorites/remove_item",
                    "players/add_currently_playing_to_favorites",
                ] {
                    $0.override(command, result: .null)
                }
            })
    }

    private func sent(_ rig: BackendRig, _ command: String) -> [SentRequest] {
        rig.transport.sentRequests.filter { $0.command == command }
    }

    @Test func addSendsTheURI() async throws {
        let rig = try await rig()
        #expect(rig.backend.capabilities.contains(.favorites))
        try await rig.backend.setFavorite(MediaID(.album, "spotify://album/abc"), true)
        let request = try #require(sent(rig, "music/favorites/add_item").first)
        #expect(request.args["item"] == .string("spotify://album/abc"))

        try await rig.backend.setFavorite(MediaID(.track, "library://track/42"), false)
        let remove = try #require(sent(rig, "music/favorites/remove_item").first)
        #expect(remove.args["media_type"] == .string("track"))
        #expect(remove.args["library_item_id"] == .string("42"))
        await rig.backend.disconnect()
    }

    @Test func removeNeedsALibraryID() async throws {
        let rig = try await rig()
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.unfavoriteNeedsLibraryText)) {
            try await rig.backend.setFavorite(MediaID(.track, "spotify://track/xyz"), false)
        }
        #expect(sent(rig, "music/favorites/remove_item").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func favoriteCurrentTrackUsesThePlayer() async throws {
        let rig = try await rig()
        _ = try await rig.backend.outputs()
        try await rig.backend.favoriteCurrentTrack(on: OutputDevice.ID(rawValue: SyntheticPlayback.playerID))
        let request = try #require(sent(rig, "players/add_currently_playing_to_favorites").first)
        #expect(request.args["player_id"] == .string(SyntheticPlayback.playerID))
        await rig.backend.disconnect()
    }
}
