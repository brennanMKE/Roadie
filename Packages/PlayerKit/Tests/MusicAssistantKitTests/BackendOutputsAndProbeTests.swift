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

    @Test func playTransportAndNowPlayingAreNotSupportedYet() async throws {
        let rig = try await connectedBackend()
        let output = OutputDevice.ID(rawValue: "ap82fe09484ac9")
        await #expect(throws: MusicBackendError.unsupported(.remoteOutputs)) {
            try await rig.backend.play([MediaID(.album, "library://album/27")], on: output, mode: .replace())
        }
        await #expect(throws: MusicBackendError.unknownOutput(OutputDevice.ID(rawValue: "nope"))) {
            try await rig.backend.play([], on: OutputDevice.ID(rawValue: "nope"), mode: .append)
        }
        await #expect(throws: MusicBackendError.unsupported(.remoteOutputs)) {
            try await rig.backend.transport(.play, on: output)
        }
        var received = 0
        for await _ in await rig.backend.nowPlaying(on: output) { received += 1 }
        #expect(received == 0)
        let sent = rig.transport.sentRequests.map(\.command)
        #expect(!sent.contains { $0.hasPrefix("players/cmd/") })
        #expect(!sent.contains("player_queues/play_media"))
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

    @Test func capabilitiesExcludeOutputsUntilControllerMode() throws {
        let rig = try makeBackend()
        #expect(rig.backend.capabilities == [.search, .playlists, .artwork])
        #expect(rig.backend.sourceID == "musicAssistant")
        #expect(rig.backend.displayName == "Music Assistant")
    }
}
