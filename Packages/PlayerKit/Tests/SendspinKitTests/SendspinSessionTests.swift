import Foundation
import Testing
@testable import SendspinKit

@Suite(.timeLimit(.minutes(1)))
struct SendspinSessionTests {
    private func synchronizedCount(_ recorder: EventRecorder) -> Int {
        recorder.events.filter { $0 == .synchronized }.count
    }

    private func startSynchronized(
        _ transport: StubSendspinTransport = StubSendspinTransport(), sleeper: TestSleeper = TestSleeper()
    ) async throws -> (SendspinSession, StubSendspinTransport, EventRecorder, StubSendspinTransportFactory) {
        let factory = StubSendspinTransportFactory([transport])
        let session = makeSession(factory: factory, sleeper: sleeper)
        let recorder = await EventRecorder(session)
        await session.start()
        try #require(await waitFor { recorder.contains { $0 == .synchronized } })
        return (session, transport, recorder, factory)
    }

    @Test func handshakeSendsAuthThenHelloThenTimeThenState() async throws {
        let (session, transport, _, _) = try await startSynchronized()
        let types = transport.sentTypes
        #expect(types.first == "auth")
        #expect(types.dropFirst().first == "client/hello")
        let stateIndex = try #require(types.firstIndex(of: "client/state"))
        #expect(types[2..<stateIndex].allSatisfy { $0 == "client/time" })
        #expect(stateIndex - 2 >= 2 * SendspinClockBurst.defaultSize)
        let auth = jsonObject(transport.sent[0])
        #expect(auth["token"] as? String == testToken)
        #expect(auth["client_id"] as? String == testClientID)
        #expect(transport.sent[0].components(separatedBy: testToken).count == 2)
        #expect(transport.sent.dropFirst().allSatisfy { !$0.contains(testToken) })
        #expect(!String(describing: testConfiguration()).contains(testToken))
        await session.stop(reason: .shutdown)
    }

    @Test func unauthorizedCloseStopsWithoutRetry() async throws {
        let factory = StubSendspinTransportFactory([StubSendspinTransport(auth: .unauthorized)])
        let session = makeSession(factory: factory)
        let recorder = await EventRecorder(session)
        await session.start()
        #expect(await waitFor { recorder.contains { $0 == .disconnected(.unauthorized("Invalid or expired token")) } })
        try await Task.sleep(for: .milliseconds(100))
        #expect(factory.made.count == 1)
        #expect(!recorder.contains { $0 == .synchronized })
    }

    @Test func availableIsSentOnlyAfterConvergence() async throws {
        let transport = StubSendspinTransport()
        transport.holdTime(true)
        let factory = StubSendspinTransportFactory([transport])
        let session = makeSession(factory: factory)
        let recorder = await EventRecorder(session)
        await session.start()
        #expect(await waitFor { transport.sentTypes.contains("client/time") })
        try await Task.sleep(for: .milliseconds(50))
        let availableStates = { transport.sent.filter { text in
            let object = jsonObject(text)
            return object["type"] as? String == "client/state"
                && (object["payload"] as? [String: Any])?["available"] as? Bool == true
        } }
        #expect(availableStates().isEmpty)
        #expect(await session.localMicros(forServer: 1) == nil)
        transport.holdTime(false)
        #expect(await waitFor { recorder.contains { $0 == .synchronized } })
        #expect(availableStates().count == 1)
        let firstAvailable = try #require(transport.sent.firstIndex { availableStates().contains($0) })
        #expect(transport.sentTypes[..<firstAvailable].filter { $0 == "client/time" }.count >= 2 * SendspinClockBurst.defaultSize)
        await session.stop(reason: .shutdown)
    }

    @Test func audioEventsCarryServerTimeAndPayload() async throws {
        let (session, transport, recorder, _) = try await startSynchronized()
        var data = Data([4])
        withUnsafeBytes(of: Int64(9_000_000_000).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [9, 8, 7, 6])
        transport.push(.binary(data))
        transport.push(.binary(Data([8, 1, 2])))
        #expect(await waitFor { recorder.contains { if case .audio = $0 { true } else { false } } })
        let expectedLocal = await session.localMicros(forServer: 9_000_000_000)
        let audio = recorder.events.compactMap { event -> (SendspinAudioChunk, Int64)? in
            if case .audio(let chunk, let local) = event { (chunk, local) } else { nil }
        }
        #expect(audio.count == 1)
        #expect(audio.first?.0 == SendspinAudioChunk(serverMicros: 9_000_000_000, payload: Data([9, 8, 7, 6])))
        #expect(audio.first?.1 == expectedLocal)
        await session.stop(reason: .shutdown)
    }

    @Test func streamStartClearEndAreForwardedInOrder() async throws {
        let (session, transport, recorder, _) = try await startSynchronized()
        transport.push(.text(try fixtureText(type: "stream/start")))
        transport.push(.text(try fixtureText(type: "stream/clear")))
        transport.push(.text(try fixtureText(type: "stream/end")))
        #expect(await waitFor { recorder.contains { $0 == .streamEnded } })
        let stream = recorder.events.filter {
            switch $0 {
            case .streamStarted, .streamCleared, .streamEnded: true
            default: false
            }
        }
        guard stream.count == 3, case .streamStarted(let format) = stream[0] else {
            Issue.record("unexpected events \(stream)")
            return
        }
        #expect(format.codec == "pcm")
        #expect(format.sampleRate == 48_000)
        #expect(format.channels == 2)
        #expect(format.bitDepth == 16)
        #expect(stream[1] == .streamCleared)
        #expect(stream[2] == .streamEnded)
        await session.stop(reason: .shutdown)
    }

    @Test func volumeCommandIsForwardedAndReportSendsFullState() async throws {
        let (session, transport, recorder, _) = try await startSynchronized()
        transport.push(.text(try fixtureText(type: "server/command", index: 0)))
        transport.push(.text(try fixtureText(type: "server/command", index: 1)))
        #expect(await waitFor { recorder.contains { $0 == .setMute(true) } })
        #expect(recorder.contains { $0 == .setVolume(42) })
        await session.report(volume: 42, muted: true)
        let last = jsonObject(try #require(transport.sent.last))
        #expect(last["type"] as? String == "client/state")
        let payload = try #require(last["payload"] as? [String: Any])
        #expect(payload["available"] as? Bool == true)
        let player = try #require(payload["player"] as? [String: Any])
        #expect(player["volume"] as? Int == 42)
        #expect(player["muted"] as? Bool == true)
        #expect(player["static_delay_ms"] as? Int == 0)
        #expect(player["required_lead_time_ms"] as? Int == 300)
        #expect(player["min_buffer_ms"] as? Int == 150)
        #expect(player["supported_commands"] as? [String] == [])
        await session.stop(reason: .shutdown)
    }

    @Test func unexpectedCloseReconnectsWithBackoffAndResetsTheFilter() async throws {
        let sleeper = TestSleeper()
        let second = StubSendspinTransport()
        second.holdTime(true)
        let first = StubSendspinTransport()
        let factory = StubSendspinTransportFactory([first, second])
        let session = makeSession(factory: factory, sleeper: sleeper)
        let recorder = await EventRecorder(session)
        await session.start()
        #expect(await waitFor { recorder.contains { $0 == .synchronized } })
        #expect(await session.localMicros(forServer: 1) != nil)
        first.push(.closed(code: 1006, reason: nil))
        #expect(await waitFor { second.sentTypes.contains("client/time") })
        #expect(factory.made.count == 2)
        #expect(recorder.contains { if case .disconnected(.some) = $0 { true } else { false } })
        #expect(sleeper.sleeps.contains(.seconds(1)))
        #expect(await session.localMicros(forServer: 1) == nil)
        second.holdTime(false)
        #expect(await waitFor { synchronizedCount(recorder) == 2 })
        #expect(await session.localMicros(forServer: 1) != nil)
        await session.stop(reason: .shutdown)
    }

    @Test func stopSendsGoodbyeAndDoesNotReconnect() async throws {
        let (session, transport, recorder, factory) = try await startSynchronized()
        await session.stop(reason: .userRequest)
        let last = jsonObject(try #require(transport.sent.last))
        #expect(last["type"] as? String == "client/goodbye")
        #expect((last["payload"] as? [String: Any])?["reason"] as? String == "user_request")
        #expect(await waitFor { recorder.contains { $0 == .disconnected(nil) } })
        try await Task.sleep(for: .milliseconds(100))
        #expect(factory.made.count == 1)
        #expect(!recorder.contains { if case .disconnected(.some) = $0 { true } else { false } })
    }

    @Test func localMicrosMapsServerTimeThroughTheFilter() async throws {
        let (session, transport, _, _) = try await startSynchronized()
        let server: Int64 = 50_000_000
        let local = try #require(await session.localMicros(forServer: server))
        // The fake server is `offset` ahead with a symmetric-enough path: local ≈ server − offset.
        #expect(abs(local - (server - transport.server.offset)) < 100)
        await session.stop(reason: .shutdown)
    }
}
