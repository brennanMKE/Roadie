import Foundation
import SendspinKit
import Testing
@testable import AudioCore
@testable import SendspinPlayback

@MainActor
final class Rig {
    let offline: OfflinePlayer
    let factory = FakeSessionFactory()
    let bridge: SendspinPlayer
    var started = 0
    var preempted = 0
    var session: FakeSendspinSession { factory.session }
    var player: Player { offline.player }

    init() throws {
        offline = try OfflinePlayer()
        let factory = factory
        bridge = SendspinPlayer(player: offline.player) { factory.make($0) }
        bridge.onStreamStarted = { [unowned self] in started += 1 }
        bridge.onStreamPreempted = { [unowned self] in preempted += 1 }
    }

    func connect() async throws {
        bridge.start(testConfiguration)
        session.push(.connected(try serverHello()))
        #expect(await waitUntil { await self.session.reports.count == 1 })
    }

    func startStream() async {
        session.push(.streamStarted(pcm16Stereo44k))
        #expect(await waitUntil { self.bridge.isStreaming })
    }

    func reports() async -> [FakeSendspinSession.Report] { await session.reports }
}

@MainActor
@Suite struct SendspinPlayerTests {
    @Test func constructionStartsNothing() {
        let factory = FakeSessionFactory()
        let player = Player()
        let bridge = SendspinPlayer(player: player) { factory.make($0) }
        #expect(factory.made == 0)
        #expect(bridge.status == .off)
        #expect(!bridge.isStreaming)
        #expect(player.state == .stopped)
        #expect(player._graph == nil)
    }

    @Test func advertisedFormatIsSixteenBitStereoAtTheOutputRate() throws {
        let rig = try Rig()
        let format = rig.bridge.advertisedFormat()
        #expect(format.codec == "pcm")
        #expect(format.channels == 2)
        #expect(format.bitDepth == 16)
        #expect(format.sampleRate == Int(rig.player.streamOutputSampleRate.rounded()))
    }

    @Test func streamStartBeginsThePlayersStreamAndNotifies() async throws {
        let rig = try Rig()
        try await rig.connect()
        #expect(rig.bridge.status == .connected(serverName: "Test Server"))
        #expect(await rig.session.started == 1)
        await rig.startStream()
        #expect(rig.player.isStreaming)
        #expect(rig.started == 1)
        await rig.bridge.stop()
    }

    @Test func audioChunksReachThePlayerAndRender() async throws {
        let rig = try Rig()
        try await rig.connect()
        await rig.startStream()
        let frames = 882   // 20 ms
        for i in 0..<10 {
            let pcm = sinePCM16(hz: 1000, amplitude: 0.1, frames: frames, startFrame: i * frames, rate: OfflinePlayer.rate)
            rig.session.push(.audio(SendspinAudioChunk(serverMicros: Int64(i) * 20_000, payload: pcm), localMicros: Int64(i) * 20_000))
        }
        #expect(await waitUntil { rig.player.state == .playing })
        try await Task.sleep(for: .milliseconds(100))
        let left = try await rig.offline.renderFrames(blocks: 20)
        let rms = OfflinePlayer.rms(left[(4 * 512)..<(14 * 512)])
        #expect(rms > 0.02)
        await rig.bridge.stop()
    }

    @Test func streamEndStopsThePlayer() async throws {
        let rig = try Rig()
        try await rig.connect()
        await rig.startStream()
        rig.session.push(.streamEnded)
        #expect(await waitUntil { !rig.bridge.isStreaming })
        #expect(!rig.player.isStreaming)
        #expect(rig.player.state == .stopped)
        #expect(rig.preempted == 0)
        await rig.bridge.stop()
    }

    @Test func streamClearClearsWithoutEnding() async throws {
        let rig = try Rig()
        try await rig.connect()
        await rig.startStream()
        rig.session.push(.streamCleared)
        rig.session.push(.setVolume(55))   // a marker: handled after the clear
        #expect(await waitUntil { rig.player.volume == 0.55 })
        #expect(rig.bridge.isStreaming)
        #expect(rig.player.isStreaming)
        #expect(rig.preempted == 0)
        await rig.bridge.stop()
    }

    @Test func volumeCommandSetsPlayerVolumeAndReportsIt() async throws {
        let rig = try Rig()
        try await rig.connect()
        rig.session.push(.setVolume(40))
        #expect(await waitUntil { await rig.reports().count == 2 })
        #expect(rig.player.volume == 0.4)
        #expect(await rig.reports().last == FakeSendspinSession.Report(volume: 40, muted: false))
        try await Task.sleep(for: .milliseconds(400))
        #expect(await rig.reports().count == 2)   // no echo after the debounce
        await rig.bridge.stop()
    }

    @Test func muteAndUnmuteRestoreTheVolume() async throws {
        let rig = try Rig()
        try await rig.connect()
        rig.session.push(.setVolume(70))
        rig.session.push(.setMute(true))
        #expect(await waitUntil { await rig.reports().count == 3 })
        #expect(rig.player.volume == 0)
        #expect(await rig.reports().last == FakeSendspinSession.Report(volume: 70, muted: true))
        rig.session.push(.setMute(false))
        #expect(await waitUntil { await rig.reports().count == 4 })
        #expect(rig.player.volume == 0.7)
        #expect(await rig.reports().last == FakeSendspinSession.Report(volume: 70, muted: false))
        try await Task.sleep(for: .milliseconds(400))
        #expect(await rig.reports().count == 4)
        await rig.bridge.stop()
    }

    @Test func localVolumeChangeIsReportedOnceAfterDebounce() async throws {
        let rig = try Rig()
        try await rig.connect()
        rig.player.volume = 0.2
        try await Task.sleep(for: .milliseconds(20))
        rig.player.volume = 0.3
        try await Task.sleep(for: .milliseconds(20))
        rig.player.volume = 0.35
        #expect(await waitUntil { await rig.reports().count >= 2 })
        try await Task.sleep(for: .milliseconds(400))
        let reports = await rig.reports()
        #expect(reports.count == 2)
        #expect(reports.last == FakeSendspinSession.Report(volume: 35, muted: false))
        await rig.bridge.stop()
    }

    @Test func localPlaybackPreemptsAndNotifies() async throws {
        let rig = try Rig()
        try await rig.connect()
        await rig.startStream()
        let url = URL(fileURLWithPath: "/nonexistent/skinamp-test.mp3")
        rig.player.enqueue([Track(title: "Local", artist: "Test", duration: 1, source: .file(url))])
        rig.player.play(at: 0)
        #expect(rig.preempted == 1)
        #expect(!rig.bridge.isStreaming)
        #expect(!rig.player.isStreaming)
        await rig.bridge.stop()
        #expect(rig.preempted == 1)
    }

    @Test func disconnectEndsTheStreamAndShowsStatus() async throws {
        let rig = try Rig()
        try await rig.connect()
        await rig.startStream()
        rig.session.push(.disconnected(.transport("closed")))
        #expect(await waitUntil { !rig.bridge.isStreaming })
        #expect(!rig.player.isStreaming)
        #expect(rig.bridge.status == .failed(SendspinError.transport("closed").localizedDescription))
        #expect(rig.preempted == 0)
        rig.session.push(.connected(try serverHello()))
        #expect(await waitUntil { rig.bridge.status == .connected(serverName: "Test Server") })
        await rig.bridge.stop()
        #expect(rig.bridge.status == .off)
        #expect(await rig.session.stops == [.shutdown])
    }

    @Test func unauthorizedLeavesFailedStatus() async throws {
        let rig = try Rig()
        rig.bridge.start(testConfiguration)
        #expect(rig.bridge.status == .connecting)
        rig.session.push(.disconnected(.unauthorized(nil)))
        #expect(await waitUntil { rig.bridge.status != .connecting })
        #expect(rig.bridge.status == .failed(SendspinError.unauthorized(nil).localizedDescription))
        await rig.bridge.stop()
    }
}
