import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// A real `Player` in offline manual rendering over a `TrickleByteSource`: the test decides when bytes
/// arrive and when audio is pulled, so nothing depends on timing or reaches a speaker.
@MainActor
final class ProgressiveRig {
    let dir: URL
    let player: Player
    let source: TrickleByteSource
    let track: Track
    let wavURL: URL
    let engine: AVAudioEngine
    let out: AVAudioPCMBuffer
    var peaks: [Float] = []
    var rendered = 0

    /// `bufferFrames` 4096 with the default window of 8 holds the whole 22,050-frame track, so a fully
    /// available source schedules everything without any rendering.
    init(
        available: Double, bufferFrames: AVAudioFrameCount = 4096, prerollSeconds: TimeInterval = 0.05,
        policy edit: (inout ProgressiveReadPolicy) -> Void = { _ in }
    ) throws {
        dir = try ProgressiveFixtures.makeDir()
        let wav = try ProgressiveFixtures.wav(in: dir)
        wavURL = wav.url
        source = TrickleByteSource(data: wav.data, available: 0)
        source.advance(to: Int64(Double(wav.data.count) * available))
        track = TrickleResolver.plexTrack(for: source)
        player = Player(resolver: TrickleResolver(source: source, wholeFile: wav.url))
        player.recordsDiagnostics = true
        var policy = ProgressiveReadPolicy()
        policy.prerollSeconds = prerollSeconds
        policy.minimumPrerollBytes = 8192
        edit(&policy)
        player.progressivePolicy = policy
        player.progressiveBufferFrames = bufferFrames
        try renderSilently(player)
        engine = player.ensureGraph().engine
        out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    }

    func cleanup() {
        player.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    var feeder: ProgressiveFeeder? { player.progressive?.feeder }

    func waitPlaying() async -> Bool { await waitUntil { player.state == .playing } }

    @discardableResult
    func renderBlock() throws -> Float {
        let status = try engine.renderOffline(512, to: out)
        #expect(status == .success)
        let data = out.floatChannelData![0]
        var peak: Float = 0
        for i in 0..<Int(out.frameLength) { peak = max(peak, abs(data[i])) }
        peaks.append(peak)
        rendered += Int(out.frameLength)
        return peak
    }

    /// Renders until every frame scheduled so far has been pulled through the node (the last block may carry
    /// silent padding).
    func renderAllScheduled() throws {
        while let feeder, rendered < Int(feeder.framesScheduled) { try renderBlock() }
    }

    var audibleBlocks: Int { peaks.filter { $0 > 0.01 }.count }

    /// Pulls audio as the feeder supplies it, until the last buffer is queued and rendered, plus a few blocks.
    func renderUntilFinished(seconds: Int = 15) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            guard let feeder else { break }
            if rendered < Int(feeder.framesScheduled) {
                try renderBlock()
            } else if feeder.hasScheduledLastBuffer {
                break
            } else {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        for _ in 0..<4 { try renderBlock() }
    }
}

@MainActor
final class SeekLog {
    var values: [TimeInterval] = []
}

@MainActor
@Suite struct ProgressivePlayerRenderTests {
    @Test func playbackStartsBeforeTheDownloadFinishesAndRendersEveryFrame() async throws {
        let rig = try ProgressiveRig(available: 0.25, bufferFrames: 1024)
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await rig.waitPlaying())
        #expect(rig.source.availableBytes < rig.source.finalSize)   // playing before the download is done
        #expect(rig.player.usesProgressiveSource)

        // Render only while two buffers stay queued behind the block, so the node never runs dry; advance the
        // download when the feeder is starved. Whatever the thread timing, the order of events is the same.
        let stages: [Double] = [0.7, 1.0]
        var stage = 0
        var scheduledAtAdvance = Int64(-1)
        let margin = 2 * 1024
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            let feeder = try #require(rig.feeder)
            let scheduled = Int(feeder.framesScheduled)
            if feeder.hasScheduledLastBuffer {
                while rig.rendered < scheduled + 4096 { try rig.renderBlock() }
                break
            }
            if scheduled - rig.rendered >= 512 + margin {
                try rig.renderBlock()
            } else if feeder.isWaitingForBytes, feeder.framesScheduled > scheduledAtAdvance, stage < stages.count {
                scheduledAtAdvance = feeder.framesScheduled
                rig.source.advance(toFraction: stages[stage])
                stage += 1
            } else {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(rig.feeder?.hasScheduledLastBuffer == true)
        #expect(!rig.player.isBuffering)
        let first = try #require(rig.peaks.firstIndex { $0 > 0.01 })
        let last = try #require(rig.peaks.lastIndex { $0 > 0.01 })
        #expect((last - first + 1) * 512 >= 22050 - 512)
        #expect((last - first + 1) * 512 <= 22050 + 1024)
        #expect(rig.peaks[first...last].filter { $0 <= 0.01 }.isEmpty)
    }

    @Test func aStallPausesTheTimelineAndResumesWhereItStopped() async throws {
        let rig = try ProgressiveRig(available: 0.25, bufferFrames: 1024)
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await rig.waitPlaying())
        #expect(await waitUntil { rig.feeder?.isWaitingForBytes == true })
        try rig.renderAllScheduled()
        #expect(await waitUntil { rig.player.isBuffering })
        let heldAt = rig.player.currentTime
        #expect(heldAt > 0)
        let audibleBefore = rig.audibleBlocks
        for _ in 0..<50 { #expect(try rig.renderBlock() <= 0.01) }
        rig.rendered -= 50 * 512   // the node was paused: those blocks consumed none of the queued audio
        rig.player.updateCurrentTime()
        #expect(abs(rig.player.currentTime - heldAt) < 512.0 / 44100)
        #expect(rig.audibleBlocks == audibleBefore)

        rig.source.advance(to: rig.source.finalSize)
        #expect(await waitUntil { !rig.player.isBuffering })
        try await rig.renderUntilFinished()
        let audible = rig.audibleBlocks * 512
        #expect(audible >= 22050 - 1024 && audible <= 22050 + 1024, "audible frames \(audible)")
    }

    @Test func seekBeyondTheDownloadedBytesClampsToBufferedTime() async throws {
        let rig = try ProgressiveRig(available: 0.5)
        defer { rig.cleanup() }
        let log = SeekLog()
        rig.player.addEventObserver { if case .seeked(let t) = $0 { log.values.append(t) } }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await rig.waitPlaying())

        rig.player.seek(to: 0.45)
        let buffered = try #require(rig.player.bufferedTime)
        #expect(abs(buffered - (0.25 - 0.05)) < 0.05, "bufferedTime \(buffered)")
        #expect(rig.player.currentTime <= buffered + 0.001)
        #expect(log.values.count == 1 && log.values[0] <= buffered + 0.001)

        rig.source.advance(to: rig.source.finalSize)
        rig.player.seek(to: 0.45)
        #expect(abs(rig.player.currentTime - 0.45) < 0.01)
        #expect(log.values.count == 2 && abs(log.values[1] - 0.45) < 0.01)
        #expect(rig.player.bufferedTime.map { abs($0 - 0.5) < 0.01 } == true)
    }

    @Test func pauseWhileBufferingKeepsTheNodeStopped() async throws {
        let rig = try ProgressiveRig(available: 0.25, bufferFrames: 1024)
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await rig.waitPlaying())
        #expect(await waitUntil { rig.feeder?.isWaitingForBytes == true })
        try rig.renderAllScheduled()
        #expect(await waitUntil { rig.player.isBuffering })

        rig.player.pause()
        #expect(rig.player.state == .paused)
        rig.source.advance(to: rig.source.finalSize)
        #expect(await waitUntil { !rig.player.isBuffering })
        #expect(rig.player.state == .paused)
        for _ in 0..<10 { #expect(try rig.renderBlock() <= 0.01) }

        rig.player.play()
        #expect(rig.player.state == .playing)
        var heard = false
        for _ in 0..<8 where try rig.renderBlock() > 0.01 { heard = true }
        #expect(heard)
    }

    @Test func theNextFileIsScheduledBehindTheLastBuffer() async throws {
        let rig = try ProgressiveRig(available: 0.4, bufferFrames: 4096)
        defer { rig.cleanup() }
        let second = rig.dir.appending(path: "second.wav")
        try GaplessRenderTests.writeSine(to: second, hz: 882)
        rig.player.enqueue([rig.track, try Track.file(at: second)])
        rig.player.play()
        #expect(await rig.waitPlaying())
        #expect(await waitUntil { rig.feeder?.isWaitingForBytes == true })
        #expect(rig.feeder?.hasScheduledLastBuffer == false)
        #expect(!rig.player.hasPreScheduledNext)

        rig.source.advance(to: rig.source.finalSize)
        #expect(await waitUntil { rig.player.hasPreScheduledNext })
        #expect(rig.feeder?.hasScheduledLastBuffer == true)
        let total = 22050 * 2 + 4096
        while rig.rendered < total { try rig.renderBlock() }
        let first = try #require(rig.peaks.firstIndex { $0 > 0.01 })
        let last = try #require(rig.peaks.lastIndex { $0 > 0.01 })
        let span = (last - first + 1) * 512
        #expect(span >= 22050 * 2 - 1024 && span <= 22050 * 2 + 1024, "span \(span)")
        #expect(rig.peaks[first...last].filter { $0 <= 0.01 }.isEmpty)
    }

    @Test func eqPreampAttenuatesProgressiveAudio() async throws {
        func peak(preamp: Float) async throws -> Float {
            let rig = try ProgressiveRig(available: 1.0)
            defer { rig.cleanup() }
            rig.player.eq = EQState(preamp: preamp)
            rig.player.enqueue([rig.track])
            rig.player.play()
            #expect(await rig.waitPlaying())
            #expect(await waitUntil { rig.feeder?.hasScheduledLastBuffer == true })
            for _ in 0..<20 { try rig.renderBlock() }
            return rig.peaks.max() ?? 0
        }
        let flat = try await peak(preamp: 0)
        let quiet = try await peak(preamp: -12)
        #expect(abs(flat - 0.5) < 0.02, "flat peak \(flat)")
        #expect(abs(quiet - 0.5 * pow(10, -12 / 20)) < 0.02, "attenuated peak \(quiet)")
    }

    @Test func analyzerTapSeesProgressiveAudio() async throws {
        let rig = try ProgressiveRig(available: 1.0)
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await waitUntil { rig.player.state == .playing && rig.player.analyzer.isInstalled })
        for i in 0..<40 {
            try rig.renderBlock()
            if i % 8 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(await waitUntil { rig.player.analyzer.latestFrame() != nil })
        let frame = try #require(rig.player.analyzer.latestFrame())
        let map = try #require(rig.player.analyzer.columnMap)
        let peakColumn = frame.spectrum.firstIndex(of: frame.spectrum.max()!)!
        #expect(frame.spectrum.max()! > 0.3)
        #expect(map.ranges[peakColumn].contains(map.bin(forFrequency: 441)))
    }

    @Test func stopTearsDownTheFeederAndClosesTheSource() async throws {
        let rig = try ProgressiveRig(available: 0.25, bufferFrames: 1024)
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await rig.waitPlaying())
        rig.player.stop()
        #expect(await waitUntil { rig.source.isClosed })
        #expect(rig.player.state == .stopped)
        #expect(rig.player.currentTime == 0)
        #expect(rig.player.bufferedTime == nil)
        #expect(!rig.player.usesProgressiveSource)
        #expect(!rig.player.isBuffering)
    }

    @Test func aNonStreamableSourceFallsBackToTheFile() async throws {
        let rig = try ProgressiveRig(available: 0) { policy in
            policy.maxSideFetchBytes = 0
            policy.waitWindowBytes = 0
        }
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await rig.waitPlaying())
        #expect(!rig.player.usesProgressiveSource)
        #expect(await waitUntil { rig.source.isClosed })
        #expect(rig.player.errorMessage == nil)
        for _ in 0..<(22050 / 512 + 12) { try rig.renderBlock() }
        let audible = rig.audibleBlocks * 512
        #expect(audible >= 22050 - 1024 && audible <= 22050 + 1024, "audible frames \(audible)")
    }

    @Test func aFailingDownloadStopsWithItsMessage() async throws {
        let rig = try ProgressiveRig(available: 0.1)
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await waitUntil { rig.source.waitCount > 0 })
        rig.source.fail(ProgressiveTestError())
        #expect(await waitUntil { rig.player.state == .stopped && rig.player.errorMessage != nil })
        #expect(rig.player.errorMessage == ProgressiveTestError().localizedDescription)
        #expect(await waitUntil { rig.source.isClosed })
    }

    @Test func invalidBytesFailTheTrackWithoutOpeningTheDevice() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = TrickleByteSource(data: ProgressiveFixtures.randomData(8192), available: 8192)
        let player = Player(resolver: TrickleResolver(source: source, wholeFile: dir.appending(path: "none.wav")))
        player.enqueue([TrickleResolver.plexTrack(for: source)])
        player.play()
        #expect(await waitUntil { player.state == .stopped && player.errorMessage != nil })
        #expect(player._graph == nil)
        #expect(await waitUntil { source.isClosed })
    }

    /// A device change during the preroll stops the engine while the track is still `.loading`. The feeder is
    /// already queued, so its first buffer must not start a node whose engine is stopped (an Objective-C
    /// exception); the change restarts the engine and the feeder from the start.
    @Test func deviceChangeDuringThePrerollRestartsTheEngineAndTheFeeder() async throws {
        let rig = try ProgressiveRig(available: 0.25) { $0.minimumPrerollBytes = 1 << 30 }
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await waitUntil { rig.feeder?.isWaitingForBytes == true })
        #expect(rig.player.state == .loading)
        let first = try #require(rig.feeder)

        rig.engine.stop()   // what a device change does to the real engine
        rig.player.reconfigureOutput()
        #expect(rig.engine.isRunning)
        #expect(rig.feeder !== first)
        #expect(rig.player.state == .loading)

        rig.source.advance(toFraction: 1.0)
        #expect(await rig.waitPlaying())
        try await rig.renderUntilFinished()
        let audible = rig.audibleBlocks * 512
        #expect(audible >= 22050 - 1024 && audible <= 22050 + 1024, "audible frames \(audible)")
    }

    @Test func deviceChangeRestartsTheFeederAtTheSamePosition() async throws {
        let rig = try ProgressiveRig(available: 1.0)
        defer { rig.cleanup() }
        rig.player.enqueue([rig.track])
        rig.player.play()
        #expect(await rig.waitPlaying())
        #expect(await waitUntil { rig.feeder?.hasScheduledLastBuffer == true })
        for _ in 0..<17 { try rig.renderBlock() }
        rig.player.updateCurrentTime()
        let before = rig.player.currentTime
        #expect(abs(before - 17.0 * 512 / 44100) < 0.002)

        rig.player.reconfigureOutput()
        #expect(abs(rig.player.currentTime - before) < 0.002)
        #expect(await waitUntil { rig.feeder?.hasScheduledLastBuffer == true })
        #expect(await waitUntil { rig.player._graph?.playerNode.isPlaying == true })
        // The restart queues the rest of the track from the resume frame, so the audio before and after
        // the restart adds up to the whole track.
        let audibleBefore = rig.audibleBlocks
        for _ in 0..<(22050 / 512 + 8) { try rig.renderBlock() }
        let audible = rig.audibleBlocks * 512
        #expect(audibleBefore == 17)
        #expect(audible >= 22050 - 1024 && audible <= 22050 + 1024, "audible frames \(audible)")
    }
}
