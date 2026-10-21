import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

struct BackendOutputsAndProbeTests {
    @Test func outputsListEnabledVisiblePlayers() async throws {
        let rig = try await connectedBackend()
        let outputs = try await rig.backend.outputs()
        #expect(outputs.count == 8)
        #expect(!outputs.contains { $0.id.rawValue.hasPrefix("AslV4UN6") })
        #expect(outputs.allSatisfy { $0.kind == .remote })
        #expect(outputs.allSatisfy { !$0.name.isEmpty })
        #expect(Set(outputs.filter(\.isAvailable).map(\.id.rawValue)) == ["upd9b597ac", "ap82fe09484ac9", "ap720a998fd71d"])
        await rig.backend.disconnect()
    }

    @Test func browsingSendsNoTransportCommands() async throws {
        let rig = try await connectedBackend()
        _ = try await rig.backend.outputs()
        _ = try await rig.backend.artists(page: PageRequest(offset: 0, limit: 50))
        _ = try await rig.backend.albums(of: nil, page: PageRequest(offset: 0, limit: 50))
        _ = try await rig.backend.search("a", limit: 5)
        let sent = rig.transport.sentRequests.map(\.command)
        #expect(!sent.contains { $0.hasPrefix("players/cmd/") })
        #expect(!sent.contains("player_queues/play_media"))
        await rig.backend.disconnect()
    }

    /// No group exists on the reference server: this `players/all` answer is synthetic (unrecorded).
    @Test func outputsMarkGroups() async throws {
        var script = try FixtureScript.recorded(token: testToken)
        script.override(
            "players/all",
            result: [
                ["player_id": "g1", "type": "group", "name": "Downstairs", "available": true, "group_members": []],
                ["player_id": "p1", "type": "player", "name": "Kitchen", "available": true,
                 "group_members": ["p1", "p2"]],
                ["player_id": "p3", "type": "stereo_pair", "name": "Den", "available": true, "group_members": []],
                ["player_id": "p4", "type": "player", "name": "Office", "available": false],
                ["player_id": "g2", "name": "Upstairs", "available": true, "group_members": ["p5", "p6"]],
            ])
        let rig = try await connectedBackend(script: script)
        let outputs = try await rig.backend.outputs()
        #expect(Dictionary(uniqueKeysWithValues: outputs.map { ($0.id.rawValue, $0.isGroup) })
            == ["g1": true, "p1": false, "p3": false, "p4": false, "g2": true])
        #expect(outputs.first { $0.id.rawValue == "p4" }?.isAvailable == false)
        await rig.backend.disconnect()
    }

    @Test func probeUsesInfoWithoutATokenOrASocket() async throws {
        let rig = try makeBackend()
        try await rig.backend.probe()
        #expect(rig.http.requests.map(\.url.path) == ["/info"])
        #expect(rig.factory.made == 0)
        #expect(rig.tokenCalls.count == 0)

        let other = try makeBackend(address: MusicAssistantServerAddress(baseURL: testBaseURL, serverID: String(repeating: "f", count: 32)))
        do {
            try await other.backend.probe()
            Issue.record("expected unreachable")
        } catch let error as MusicBackendError {
            guard case .unreachable(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.contains("different"))
        }

        let broken = try makeBackend()
        broken.http.setResponse(pathPrefix: "/info", MAHTTPResponse(status: 500))
        do {
            try await broken.backend.probe()
            Issue.record("expected unreachable")
        } catch let error as MusicBackendError {
            guard case .unreachable = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }

        let none = try makeBackend(address: nil)
        do {
            try await none.backend.probe()
            Issue.record("expected notConfigured")
        } catch let error as MusicBackendError {
            guard case .notConfigured = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }

        let unknownID = try makeBackend(address: MusicAssistantServerAddress(baseURL: testBaseURL))
        try await unknownID.backend.probe()
    }

    @Test func serverInfoStaticDecodesInfo() async throws {
        let info = try await MusicAssistantClient.serverInfo(at: testBaseURL, http: StubHTTPTransport())
        #expect(info.schemaVersion == 65)
        #expect(info.serverID == fixtureServerID)
    }

    @Test func capabilitiesIncludeRemoteOutputs() throws {
        let rig = try makeBackend()
        #expect(rig.backend.capabilities == [.search, .playlists, .artwork, .remoteOutputs, .localOutput])
        #expect(rig.backend.sourceID == "musicAssistant")
        #expect(rig.backend.displayName == "Music Assistant")
    }
}
