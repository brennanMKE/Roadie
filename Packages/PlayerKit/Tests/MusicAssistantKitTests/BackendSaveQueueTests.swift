import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// `saveQueueAsPlaylist(on:named:)` over the stub socket (#0140). SYNTHETIC routes, shaped after
/// `player_queues/save_as_playlist` in `docs/ma-protocol/commands.json`.
struct BackendSaveQueueTests {
    let output = OutputDevice.ID(rawValue: SyntheticPlayback.playerID)

    private func rig(activeQueue: String, extra: [FixtureScript.Route] = []) async throws -> BackendRig {
        try await connectedBackend(
            script: controlScript { script in
                script.override(
                    "player_queues/get_active_queue",
                    result: ["queue_id": .string(activeQueue), "active": true, "items": 3, "current_index": 0])
                script.routes.insert(.result(command: "player_queues/save_as_playlist", .null), at: 0)
                for route in extra { script.routes.insert(route, at: 0) }
            })
    }

    private func sent(_ rig: BackendRig) -> [SentRequest] {
        rig.transport.sentRequests.filter { $0.command == "player_queues/save_as_playlist" }
    }

    @Test func saveQueueTargetsTheLeaderQueue() async throws {
        let rig = try await rig(activeQueue: "the_leader")
        _ = try await rig.backend.outputs()
        try await rig.backend.saveQueueAsPlaylist(on: output, named: "  Road Trip ")
        let request = try #require(sent(rig).first)
        #expect(request.args["queue_id"]?.stringValue == "the_leader")
        #expect(request.args["name"]?.stringValue == "Road Trip")
        await rig.backend.disconnect()
    }

    @Test func saveQueueOnAnEmptyQueueIsAClearError() async throws {
        let rig = try await rig(activeQueue: SyntheticPlayback.playerID, extra: [
            .error(command: "player_queues/save_as_playlist", code: 999, details: "QueueEmpty: Queue is empty")
        ])
        _ = try await rig.backend.outputs()
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.emptyQueueText)) {
            try await rig.backend.saveQueueAsPlaylist(on: output, named: "Road Trip")
        }
        await rig.backend.disconnect()
    }

    @Test func saveQueueNeedsAName() async throws {
        let rig = try await rig(activeQueue: SyntheticPlayback.playerID)
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.playlistNameMissingText)) {
            try await rig.backend.saveQueueAsPlaylist(on: output, named: "   ")
        }
        #expect(sent(rig).isEmpty)
        await rig.backend.disconnect()
    }
}
