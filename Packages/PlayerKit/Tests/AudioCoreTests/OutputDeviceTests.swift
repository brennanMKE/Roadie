import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import AudioCore

/// #0048: the player follows the system default output. Every test renders offline and drives a
/// `ManualOutputDeviceProvider`, so no real device is opened, bound or switched.
@MainActor
@Suite struct OutputDeviceTests {
    @MainActor final class Rig {
        let dir: URL
        let provider: ManualOutputDeviceProvider
        let player: Player
        let engine: AVAudioEngine
        let graph: AudioGraph
        let tracks: [Track]
        private let out: AVAudioPCMBuffer

        init(resolver: any TrackResolver = FileTrackResolver(), renderOffline: Bool = true) throws {
            dir = try MixedFormatSupport.makeDir()
            var tracks: [Track] = []
            for i in 0..<2 {
                let url = dir.appending(path: "f\(i).wav")
                try MixedFormatSupport.writeSine(to: url, rate: 44100, channels: 2, seconds: 1.0)
                tracks.append(try Track.file(at: url))
            }
            self.tracks = tracks
            provider = ManualOutputDeviceProvider()
            player = Player(resolver: resolver, outputDevices: provider)
            try renderSilently(player)
            graph = player.ensureGraph()
            engine = graph.engine
            out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
            player.enqueue(tracks)
        }

        func cleanup() {
            player.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        /// Renders `blocks` quanta offline and returns the loudest sample.
        @discardableResult
        func render(_ blocks: Int) throws -> Float {
            var peak: Float = 0
            for _ in 0..<blocks {
                _ = try engine.renderOffline(512, to: out)
                for i in 0..<Int(out.frameLength) { peak = max(peak, abs(out.floatChannelData![0][i])) }
            }
            return peak
        }

        /// Plays, lets the next file get pre-scheduled and renders until the position is past 0.3 s.
        func playPastZeroPointThree() async throws {
            player.recordsDiagnostics = true
            player.play()
            #expect(await waitUntil { player.state == .playing && player.hasPreScheduledNext })
            try render(40)
            #expect(await waitUntil { player.currentTime > 0.3 })
        }
    }

    @Test func deviceChangeWhilePlayingRebindsAndResumes() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try await rig.playPastZeroPointThree()
        let t0 = rig.player.currentTime
        let first = rig.tracks[0].id

        rig.provider.send(99)
        #expect(await waitUntil { rig.provider.binds == [99] && rig.player.hasPreScheduledNext })
        #expect(rig.engine.isRunning)
        #expect(rig.player.state == .playing)
        #expect(rig.player.errorMessage == nil)
        let resumed = try #require(rig.player.scheduleDiagnostics.last { $0.trackID == first })
        #expect(abs(resumed.seekOffset - t0) < 0.05, "rescheduled at \(resumed.seekOffset), was \(t0)")
        #expect(abs(rig.player.currentTime - t0) < 0.05)
        #expect(rig.player.currentTime > 0.2)

        let peak = try rig.render(40)
        #expect(peak > 0.01)
        #expect(await waitUntil { rig.player.currentTime > t0 + 0.2 })
    }

    @Test func deviceChangeWhilePausedStaysParked() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try await rig.playPastZeroPointThree()
        rig.player.pause()
        let t0 = rig.player.currentTime

        rig.provider.send(99)
        #expect(await waitUntil { rig.provider.binds == [99] && rig.player.hasPreScheduledNext })
        #expect(rig.player.state == .paused)
        #expect(rig.player.currentTime == t0)
        #expect(rig.graph.playerNode.isPlaying == false)

        rig.player.play()
        #expect(rig.player.state == .playing)
        let peak = try rig.render(40)
        #expect(peak > 0.01)
        #expect(await waitUntil { rig.player.currentTime > t0 + 0.2 })
    }

    @Test func deviceChangeWhileStoppedBindsOnNextStart() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.player.play()
        #expect(await waitUntil { rig.player.state == .playing })
        rig.player.stop()

        rig.provider.send(99)
        #expect(await waitUntil { !rig.engine.isRunning })
        #expect(rig.provider.binds.isEmpty)
        #expect(rig.player.state == .stopped)
        #expect(rig.player.errorMessage == nil)

        rig.player.play()
        #expect(await waitUntil { rig.player.state == .playing })
        #expect(rig.provider.binds == [99])
        #expect(try rig.render(40) > 0.01)
    }

    @Test func deviceChangeWhileLoadingBindsBeforePlayback() async throws {
        let gate = GateResolver()
        let rig = try Rig(resolver: gate)
        defer { rig.cleanup() }
        let track = rig.tracks[0]
        rig.player.play(at: 0)
        #expect(rig.player.state == .loading)
        #expect(await gate.waitForCalls(1))

        rig.provider.send(99)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.player.state == .loading)
        await gate.release(track.id, with: .success(rig.dir.appending(path: "f0.wav")))
        #expect(await waitUntil { rig.player.state == .playing })
        #expect(rig.provider.binds == [99])
        #expect(rig.player.currentTime == 0)
        #expect(rig.player.errorMessage == nil)
        await gate.releaseAll()
    }

    @Test func deviceChangeWithNewRateReconnectsAndKeepsSettings() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.player.eq = EQState(isEnabled: true, preamp: -3, gains: [0, 0, 0, 6, 0, 0, 0, 0, 0, 0])
        rig.player.volume = 0.4
        rig.player.balance = 0.25
        rig.player.play()
        #expect(await waitUntil { rig.player.state == .playing && rig.player.hasPreScheduledNext })
        #expect(rig.graph.processingSampleRate == 44100)
        try rig.render(40)

        // The offline stand-in for a device with another rate.
        rig.engine.stop()
        try rig.engine.enableManualRenderingMode(
            .offline, format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!, maximumFrameCount: 512)
        rig.provider.send(99)
        #expect(await waitUntil { rig.graph.processingSampleRate == 48000 && rig.player.hasPreScheduledNext })
        #expect(rig.graph.processingSampleRate == 48000)
        #expect(rig.player.analyzer.sampleRate == 48000)
        #expect(rig.graph.eq.bands[3].gain == 6)
        #expect(rig.graph.eq.globalGain == -3)
        #expect(rig.graph.eq.bypass == false)
        #expect(rig.graph.mainMixerNode.outputVolume == 0.4)
        #expect(rig.graph.playerNode.pan == 0.25)
        #expect(rig.player.state == .playing)

        let out = AVAudioPCMBuffer(pcmFormat: rig.engine.manualRenderingFormat, frameCapacity: 512)!
        var peak: Float = 0
        for _ in 0..<40 {
            _ = try rig.engine.renderOffline(512, to: out)
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(out.floatChannelData![0][i])) }
        }
        #expect(peak > 0.01)
    }

    @Test func engineNotificationAndDeviceChangeCoalesce() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.player.recordsDiagnostics = true
        rig.player.play()
        #expect(await waitUntil { rig.player.state == .playing && rig.player.hasPreScheduledNext })
        #expect(rig.player.scheduleDiagnostics.count == 2)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.engine)
        rig.provider.send(99)
        #expect(await waitUntil { rig.provider.binds == [99] && rig.player.hasPreScheduledNext })
        try await Task.sleep(for: .milliseconds(200))   // let a wrongly separate second restart show up
        #expect(rig.player.scheduleDiagnostics.count == 4)
        #expect(rig.player.state == .playing)

        rig.provider.send(100)
        #expect(await waitUntil { rig.provider.binds == [99, 100] && rig.player.hasPreScheduledNext })
        #expect(rig.player.scheduleDiagnostics.count == 6)
    }

    @Test func deviceChangeBeforeAnyGraphIsIgnored() async throws {
        let provider = ManualOutputDeviceProvider()
        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "f.wav")
        try MixedFormatSupport.writeSine(to: url, rate: 44100, channels: 2, seconds: 1.0)
        let player = Player(outputDevices: provider)
        player.enqueue([try Track.file(at: url)])
        provider.send(99)
        try await Task.sleep(for: .milliseconds(50))
        #expect(player._graph == nil)

        try renderSilently(player)
        player.play()
        #expect(await waitUntil { player.state == .playing })
        #expect(provider.binds.isEmpty)
        player.stop()
    }

    @Test func bindFailureStopsWithMessage() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.player.play()
        #expect(await waitUntil { rig.player.state == .playing })
        rig.provider.failsBinds = true
        rig.provider.send(99)
        #expect(await waitUntil { rig.player.state == .stopped })
        #expect(rig.player.errorMessage != nil)

        rig.provider.failsBinds = false
        rig.player.play()
        #expect(await waitUntil { rig.player.state == .playing })
        #expect(rig.player.errorMessage == nil)
    }
}
