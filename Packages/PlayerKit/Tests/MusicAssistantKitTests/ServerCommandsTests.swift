import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

struct ServerCommandsTests {
    private let base = URL(string: "http://ma.example.test:8095")!

    @Test func probeParsesNamesFromTheRecordedList() async throws {
        let http = StubHTTPTransport()
        let commands = await MAServerCommands.probe(transport: http, base: base)
        #expect(commands.names.count == 310)
        #expect(commands.contains("player_queues/save_as_playlist"))
        #expect(commands.contains("music/playlists/remove_playlist_tracks"))
        #expect(!commands.contains("music/playlists/move_playlist_track"))
        #expect(http.requests.map(\.url.absoluteString) == ["http://ma.example.test:8095/api-docs/commands.json"])
        #expect(http.requests[0].headers.isEmpty)
    }

    @Test func probeFailureYieldsNoCommands() async throws {
        let http = StubHTTPTransport()
        http.setFailure(pathPrefix: "/api-docs/", code: .timedOut)
        #expect(await MAServerCommands.probe(transport: http, base: base).isEmpty)

        let notFound = StubHTTPTransport()
        notFound.setResponse(pathPrefix: "/api-docs/", MAHTTPResponse(status: 404, contentType: "text/plain", body: Data()))
        #expect(await MAServerCommands.probe(transport: notFound, base: base).isEmpty)

        #expect(MAServerCommands.parse(Data("not json".utf8)).isEmpty)
    }
}

struct BackendPlaylistTests {
    @Test func unsupportedCommandErrorClearsTheFeature() async throws {
        let rig = try await connectedBackend()
        await rig.backend.awaitCommandProbe()
        let command = "music/playlists/remove_playlist_tracks"
        #expect(await rig.backend.supports(command))
        // The recorded script answers any unrouted command with error 12.
        await #expect(throws: MusicBackendError.unsupported(.playlists)) {
            _ = try await rig.backend.perform(MARequest(command: command))
        }
        #expect(await !rig.backend.supports(command))
        #expect(await rig.backend.supports("player_queues/save_as_playlist"))
        await rig.backend.disconnect()
        #expect(await rig.backend.commands.isEmpty)
    }
}
