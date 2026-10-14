import Foundation
import MusicAssistantKitStub
import Testing
@testable import MusicAssistantKit

struct ClientHandshakeTests {
    @Test func connectReadsServerInfoThenAuthenticates() async throws {
        let rig = try makeClient()
        let states = Collector(await rig.client.states())
        let info = try await rig.connect()
        #expect(info.serverID == fixtureServerID)
        let sent = rig.transport.sentRequests
        #expect(sent.count == 1)
        #expect(sent[0].command == "auth")
        #expect(sent[0].messageID == "1")
        #expect(await rig.client.state == .connected)
        #expect(await rig.client.serverInfo?.serverID == fixtureServerID)
        await rig.client.disconnect()
        #expect(await waitFor { states.items.last == .disconnected && states.items.count == 5 })
        #expect(states.items == [.disconnected, .connecting, .authenticating, .connected, .disconnected])
        states.stop()
    }

    @Test func connectRefusesToSendTheTokenWhenTheServerIDDiffers() async throws {
        let rig = try makeClient()
        await #expect(throws: MusicAssistantError.serverMismatch) {
            try await rig.connect(expectedServerID: String(repeating: "f", count: 32))
        }
        #expect(rig.transport.sent.isEmpty)
        #expect(rig.transport.closeCodes == [1000])
        #expect(await rig.client.state == .failed(.serverMismatch))
    }

    @Test func anUnsupportedSchemaIsRefusedBeforeAuth() async throws {
        for changes in [["min_supported_schema_version": MAJSON.number(99)], ["schema_version": MAJSON.number(27)]] {
            let rig = try makeClient(script: scriptWith(handshake: handshake(overriding: changes)))
            do {
                _ = try await rig.connect()
                Issue.record("expected schemaUnsupported")
            } catch let error as MusicAssistantError {
                guard case .schemaUnsupported = error else {
                    Issue.record("wrong error \(error)")
                    continue
                }
            }
            #expect(rig.transport.sent.isEmpty)
        }
    }

    @Test func aRejectedTokenThrowsTokenRejectedAndCloses() async throws {
        let rig = try makeClient(script: FixtureScript.recorded(token: MusicAssistantToken("another")))
        await #expect(throws: MusicAssistantError.tokenRejected) { try await rig.connect() }
        #expect(rig.transport.closeCodes == [1000])
        #expect(await rig.client.state == .failed(.tokenRejected))
        await #expect(throws: MusicAssistantError.notConnected) { try await rig.client.call(.time()) }
    }

    @Test func aNonServerInfoFirstFrameIsAHandshakeFailure() async throws {
        let rig = try makeClient(script: scriptWith(handshake: ["{\"hello\":1}"]))
        await #expect(throws: MusicAssistantError.handshakeFailed) { try await rig.connect() }
        #expect(rig.transport.sent.isEmpty)
    }

    @Test func aTransportConnectErrorMapsToTransportAndDoesNotReconnect() async throws {
        let rig = try makeClient(connectError: .transport(.cannotConnectToHost))
        await #expect(throws: MusicAssistantError.transport(.cannotConnectToHost)) { try await rig.connect() }
        rig.clock.advance(by: .seconds(60))
        #expect(rig.factory.made == 1)
        #expect(rig.clock.sleeperCount == 0)
    }

    @Test func connectIsIdempotentWhileConnected() async throws {
        let rig = try makeClient()
        _ = try await rig.connect()
        _ = try await rig.connect()
        #expect(rig.factory.made == 1)
        #expect(rig.transport.sent.count == 1)
        await rig.client.disconnect()
    }

    @Test func disconnectSendsCloseAndClearsState() async throws {
        let rig = try makeClient()
        _ = try await rig.connect()
        await rig.client.disconnect()
        #expect(rig.transport.closeCodes == [1000])
        #expect(await rig.client.state == .disconnected)
        #expect(await rig.client.serverInfo == nil)
        #expect(await rig.client.pendingCallCount == 0)
    }

    @Test func serverInfoStaticReadsInfoWithoutASocket() async throws {
        let http = StubHTTPTransport()
        let info = try await MusicAssistantClient.serverInfo(at: testBaseURL, http: http)
        #expect(info.schemaVersion == 65)
        #expect(http.requests.count == 1)
        #expect(http.requests[0].url.path == "/info")
        #expect(http.requests[0].headers.isEmpty)
    }
}
