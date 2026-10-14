import Foundation
import MusicAssistantKitStub
import Testing
@testable import MusicAssistantKit

struct ClientConnectionTests {
    private func recordedTransport(token: MusicAssistantToken = testToken, connectError: MusicAssistantError? = nil) throws
        -> StubWebSocketTransport
    {
        StubWebSocketTransport(script: try FixtureScript.recorded(token: token), connectError: connectError)
    }

    /// Waits for the reconnect loop's sleeper (the only one while not connected), then moves time.
    private func step(_ rig: ClientRig, by duration: Duration) async {
        #expect(await waitFor { rig.clock.sleeperCount == 1 })
        rig.clock.advance(by: duration)
    }

    @Test func reconnectPolicyDoublesAndCaps() {
        var generator = SystemRandomNumberGenerator()
        let plain = ReconnectPolicy(steps: ReconnectPolicy.default.steps, cap: .seconds(30), jitter: 0)
        let delays = (1...7).map { plain.delay(attempt: $0, using: &generator) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        let jittered = ReconnectPolicy.default
        for attempt in 1...7 {
            let base = ReconnectPolicy.seconds(delays[attempt - 1])
            for _ in 0..<50 {
                let value = ReconnectPolicy.seconds(jittered.delay(attempt: attempt, using: &generator))
                #expect(value >= base * 0.8 - 1e-9 && value <= base * 1.2 + 1e-9)
            }
        }
    }

    @Test func aServerCloseFailsPendingCallsAndReconnects() async throws {
        let second = try recordedTransport()
        let rig = try makeClient(extraTransports: [second])
        _ = try await rig.connect()
        rig.transport.holdReplies(for: "time")
        let call = Task { try await rig.client.call(.time()) }
        #expect(await waitFor { await rig.client.pendingCallCount == 1 })
        rig.transport.closeFromServer(code: 1006)
        do {
            _ = try await call.value
            Issue.record("expected the pending call to fail")
        } catch let error as MusicAssistantError {
            #expect(error == .disconnected)
        }
        #expect(await waitFor { await rig.client.state == .reconnecting(attempt: 1) })
        await step(rig, by: .seconds(1))
        #expect(await waitFor { await rig.client.state == .connected })
        #expect(rig.factory.made == 2)
        #expect(second.sentRequests.first?.command == "auth")
        #expect(second.sentRequests.first?.messageID == "1")
        let time = try await rig.client.call(.time())
        #expect(time.doubleValue != nil)
        #expect(second.sentRequests.last?.messageID == "2")
        await rig.client.disconnect()
    }

    @Test func reconnectBacksOffWhileTheServerIsDown() async throws {
        let down = MusicAssistantError.transport(.cannotConnectToHost)
        let extras = [
            try recordedTransport(connectError: down), try recordedTransport(connectError: down),
            try recordedTransport(connectError: down), try recordedTransport(),
        ]
        let rig = try makeClient(extraTransports: extras)
        _ = try await rig.connect()
        rig.transport.closeFromServer()
        // The delays are 1, 2, 4 and 8 s: an advance short of the delay makes no attempt.
        await step(rig, by: .seconds(1))
        #expect(await waitFor { rig.factory.made == 2 && rig.clock.sleeperCount == 1 })
        rig.clock.advance(by: .seconds(1))
        #expect(rig.factory.made == 2)
        await step(rig, by: .seconds(1))
        #expect(await waitFor { rig.factory.made == 3 && rig.clock.sleeperCount == 1 })
        #expect(await rig.client.state == .reconnecting(attempt: 3))
        await step(rig, by: .seconds(4))
        #expect(await waitFor { rig.factory.made == 4 && rig.clock.sleeperCount == 1 })
        await step(rig, by: .seconds(8))
        #expect(await waitFor { await rig.client.state == .connected })
        #expect(rig.factory.made == 5)
        await rig.client.disconnect()
    }

    @Test func aFailedPingReconnects() async throws {
        let second = try recordedTransport()
        let rig = try makeClient(extraTransports: [second])
        _ = try await rig.connect()
        rig.transport.pingError = .transport(.timedOut)
        #expect(await waitFor { rig.clock.sleeperCount == 1 })
        rig.clock.advance(by: .seconds(25))
        #expect(await waitFor { await rig.client.state == .reconnecting(attempt: 1) })
        #expect(rig.transport.pingCount == 1)
        await step(rig, by: .seconds(1))
        #expect(await waitFor { rig.factory.made == 2 })
        #expect(await waitFor { await rig.client.state == .connected })
        await rig.client.disconnect()
    }

    @Test func pingIsSentEveryIntervalWhileConnected() async throws {
        let rig = try makeClient()
        _ = try await rig.connect()
        #expect(await waitFor { rig.clock.sleeperCount == 1 })
        rig.clock.advance(by: .seconds(25))
        #expect(await waitFor { rig.transport.pingCount == 1 && rig.clock.sleeperCount == 1 })
        rig.clock.advance(by: .seconds(25))
        #expect(await waitFor { rig.transport.pingCount == 2 && rig.clock.sleeperCount == 1 })
        rig.transport.closeFromServer()
        #expect(await waitFor { await rig.client.state == .reconnecting(attempt: 1) })
        #expect(await waitFor { rig.clock.sleeperCount == 1 })
        #expect(rig.transport.pingCount == 2)
        await rig.client.disconnect()
    }

    @Test func disconnectStopsReconnecting() async throws {
        let rig = try makeClient(extraTransports: [try recordedTransport()])
        _ = try await rig.connect()
        rig.transport.closeFromServer()
        #expect(await waitFor { await rig.client.state == .reconnecting(attempt: 1) })
        #expect(await waitFor { rig.clock.sleeperCount == 1 })
        await rig.client.disconnect()
        #expect(await rig.client.state == .disconnected)
        rig.clock.advance(by: .seconds(60))
        #expect(rig.factory.made == 1)
    }

    @Test func aRejectedTokenAfterReconnectStopsRetrying() async throws {
        let rig = try makeClient(extraTransports: [try recordedTransport(token: MusicAssistantToken("rotated"))])
        _ = try await rig.connect()
        let events = Collector(await rig.client.events())
        rig.transport.closeFromServer()
        await step(rig, by: .seconds(1))
        #expect(await waitFor { await rig.client.state == .failed(.tokenRejected) })
        #expect(await waitFor { events.finished })
        rig.clock.advance(by: .seconds(60))
        #expect(rig.factory.made == 2)
        await #expect(throws: MusicAssistantError.notConnected) { try await rig.client.call(.time()) }
    }

    @Test func eventSubscribersSurviveAReconnect() async throws {
        let second = try recordedTransport()
        let rig = try makeClient(extraTransports: [second])
        _ = try await rig.connect()
        let events = Collector(await rig.client.events())
        rig.transport.closeFromServer()
        await step(rig, by: .seconds(1))
        #expect(await waitFor { await rig.client.state == .connected })
        second.push(#"{"event":"queue_updated","object_id":"q","data":{}}"#)
        #expect(await waitFor { events.items.count == 1 })
        #expect(events.items.first?.event == "queue_updated")
        events.stop()
        await rig.client.disconnect()
    }
}
