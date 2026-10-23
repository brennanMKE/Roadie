import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

struct SecrecyTests {
    @Test func theTokenAppearsOnlyInTheAuthFrame() async throws {
        let rig = try await connectedBackend()
        let backend = rig.backend
        _ = try await backend.artists(page: PageRequest(offset: 0, limit: 3))
        _ = try await backend.albums(of: nil, page: PageRequest(offset: 0, limit: 3))
        _ = try await backend.albums(of: MediaID(.artist, "library://artist/432"), page: .first)
        _ = try await backend.tracks(of: MediaID(.album, "library://album/27"))
        _ = try await backend.playlists(page: .first)
        _ = try await backend.tracks(ofPlaylist: MediaID(.playlist, "library://playlist/4"))
        _ = try await backend.search("008-tapbots", limit: 3)
        _ = try await backend.artwork(ArtworkRef(String(repeating: "a", count: 64)), maxPixels: 200)
        _ = try await backend.outputs()
        try await backend.probe()
        let withToken = rig.transport.sent.filter { $0.contains("ma-UNIT-TEST-TOKEN") }
        #expect(withToken.count == 1)
        let auth = try MAJSON.parse(withToken[0])
        #expect(auth["command"] == "auth")
        #expect(auth["args"]?["token"] == "ma-UNIT-TEST-TOKEN")
        for request in rig.http.requests {
            #expect(!request.url.absoluteString.contains("ma-UNIT-TEST-TOKEN"))
            #expect(request.headers.isEmpty)
        }
        await backend.disconnect()
    }

    @Test func descriptionsAndMirrorsAreRedacted() throws {
        let token = testToken
        #expect(String(describing: token) == "MusicAssistantToken(redacted)")
        #expect(String(reflecting: token) == "MusicAssistantToken(redacted)")
        #expect(Mirror(reflecting: token).children.isEmpty)
        let settings = MusicAssistantServerSettings(address: testAddress, token: token)
        #expect(String(describing: settings) == "MusicAssistantServerSettings(redacted)")
        #expect(Mirror(reflecting: settings).children.isEmpty)
        #expect(!"\(settings)".contains("ma-UNIT-TEST-TOKEN"))
        #expect(!String(reflecting: settings).contains("ma.example"))
        #expect(String(describing: MARequest.auth(token: token)) == "auth(redacted)")
        let rig = try makeBackend()
        #expect(String(describing: rig.backend) == "MusicAssistantBackend")
        #expect(Mirror(reflecting: rig.backend).children.isEmpty)
    }

    @Test func errorsCarryNoTokenHostOrFrame() async throws {
        var collected: [any Error] = []
        func attempt(_ rig: ClientRig, expectedServerID: String? = nil) async {
            do {
                _ = try await rig.connect(expectedServerID: expectedServerID)
            } catch {
                collected.append(error)
            }
        }
        let wrongToken = try makeClient(script: FixtureScript.recorded(token: MusicAssistantToken("other")))
        await attempt(wrongToken)
        let wrongServer = try makeClient()
        await attempt(wrongServer, expectedServerID: "ffff")
        let notInfo = try makeClient(script: scriptWith(handshake: ["{\"hello\":1}"]))
        await attempt(notInfo)
        let tooOld = try makeClient(script: scriptWith(handshake: handshake(overriding: ["schema_version": 10])))
        await attempt(tooOld)
        let refused = try makeClient(connectError: .transport(.cannotConnectToHost))
        await attempt(refused)

        let rig = try makeClient()
        _ = try await rig.connect()
        do {
            _ = try await rig.client.call(MARequest(command: try #require(MAFixture.errorUnknownCommand.command)))
        } catch {
            collected.append(error)
        }
        do {
            _ = try await rig.client.call(.player(id: "x"), as: MAPlayer.self)
        } catch {
            collected.append(error)
        }
        rig.transport.unanswered = ["time"]
        let timed = Task { try await rig.client.call(.time()) }
        #expect(await waitFor { rig.clock.sleeperCount == 2 })
        rig.clock.advance(by: .seconds(15))
        do {
            _ = try await timed.value
        } catch {
            collected.append(error)
        }
        await rig.client.disconnect()
        collected.append(MusicAssistantError.disconnected)
        collected.append(MusicAssistantError.notConnected)
        collected.append(MusicAssistantError.unauthenticated)
        collected.append(MusicAssistantError.invalidURL)

        #expect(collected.count >= 11)
        for error in collected {
            let texts = [error.localizedDescription, String(describing: error), String(reflecting: error)]
            for text in texts {
                for forbidden in ["ma-UNIT-TEST-TOKEN", "ma.example", "8095", "message_id"] {
                    #expect(!text.contains(forbidden), "\(forbidden) in an error")
                }
            }
        }
    }

    @Test func theTokenIsNotCodable() {
        let tokenEncodable = (MusicAssistantToken.self as Any) is any Encodable.Type
        let tokenDecodable = (MusicAssistantToken.self as Any) is any Decodable.Type
        let addressEncodable = (MusicAssistantServerAddress.self as Any) is any Encodable.Type
        #expect(!tokenEncodable)
        #expect(!tokenDecodable)
        #expect(addressEncodable)
    }
}
