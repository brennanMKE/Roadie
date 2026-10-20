import AVFoundation
import Foundation
import Testing
@testable import AudioCore

@MainActor
final class StreamEventLog {
    var events: [String] = []
}

/// A real `Player` streaming timed PCM in offline manual rendering, timed by the render sample clock.
/// Nothing reaches a device.
@MainActor
final class StreamRig {
    static let rate = 44_100.0
    static let chunkFrames = 882   // 20 ms
    let player: Player
    let engine: AVAudioEngine
    let out: AVAudioPCMBuffer
    let format = StreamFormat(sampleRate: StreamRig.rate, channels: 2, bitDepth: 16)
    let log = StreamEventLog()
    var left: [Float] = []
    var right: [Float] = []

    init(player: Player = Player()) throws {
        self.player = player
        try renderSilently(player)
        let engine = player.ensureGraph().engine
        self.engine = engine
        player.streamRenderClock = SampleStreamRenderClock(rate: Self.rate) { engine.manualRenderingSampleTime }
        out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        let log = self.log
        player.addEventObserver { event in
            switch event {
            case .streamStarted: log.events.append("started")
            case .streamEnded: log.events.append("ended")
            case .streamPreempted: log.events.append("preempted")
            default: break
            }
        }
    }

    /// Appends `count` contiguous 20 ms chunks of a sine, the first stamped `startMicros`.
    func append(_ count: Int, from startMicros: Int64 = 0, hz: Double = 1000, amplitude: Double = 0.1, firstIndex: Int = 0) {
        for i in firstIndex..<(firstIndex + count) {
            let pcm = sinePCM16(hz: hz, amplitude: amplitude, frames: Self.chunkFrames,
                                startFrame: i * Self.chunkFrames, rate: Self.rate)
            player.appendStream(StreamChunk(
                presentationMicros: startMicros + Int64(i - firstIndex) * 20_000, pcm: pcm))
        }
    }

    func render(blocks: Int) async throws {
        for block in 0..<blocks {
            let status = try engine.renderOffline(512, to: out)
            #expect(status == .success)
            let n = Int(out.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
            right.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![1], count: n))
            if block % 8 == 0 { try await Task.sleep(for: .milliseconds(2)) }
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return Float((samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot())
    }

    var nowMicros: Int64 { Int64((Double(engine.manualRenderingSampleTime) / Self.rate * 1e6).rounded()) }
}

@MainActor
@Suite struct StreamPlayerRenderTests {
    /// RMS of the left and right channels over 1 kHz audio, skipping the filters' settling.
    func renderedRMS(_ configure: (Player) -> Void) async throws -> (left: Float, right: Float) {
        let rig = try StreamRig()
        configure(rig.player)
        try rig.player.beginStream(rig.format)
        rig.append(50)
        #expect(rig.player.state == .playing)
        try await rig.render(blocks: 70)
        rig.player.endStream()
        let skip = 20 * 512
        return (StreamRig.rms(rig.left[skip...]), StreamRig.rms(rig.right[skip...]))
    }

    @Test func streamPlaysThroughTheEQAndTheAnalyzerTap() async throws {
        let flat = try await renderedRMS { _ in }
        #expect(flat.left > 0.05)   // 0.1 amplitude sine: RMS ~0.0707
        var boost = EQState.flat
        boost[band: 4] = 12   // 1 kHz
        let boosted = try await renderedRMS { $0.eq = boost }
        #expect(boosted.left / flat.left > 3.0)

        let rig = try StreamRig()
        try rig.player.beginStream(rig.format)
        rig.append(50)
        #expect(await waitUntil { rig.player.analyzer.isInstalled })
        try await rig.render(blocks: 40)
        #expect(await waitUntil { rig.player.analyzer.latestFrame() != nil })
        rig.player.endStream()
    }

    @Test func chunksScheduledBackToBackRenderWithoutGaps() async throws {
        let rig = try StreamRig()
        try rig.player.beginStream(rig.format)
        rig.append(40, hz: 441, amplitude: 0.5)
        try await rig.render(blocks: (40 * StreamRig.chunkFrames) / 512 + 4)
        let first = try #require(rig.left.firstIndex { $0 != 0 })
        let last = try #require(rig.left.lastIndex { $0 != 0 })
        #expect(last - first >= 40 * StreamRig.chunkFrames - 4)
        var run = 0
        var longest = 0
        for sample in rig.left[first...last] {
            run = sample == 0 ? run + 1 : 0
            longest = max(longest, run)
        }
        #expect(longest <= 1)
        rig.player.endStream()
    }

    @Test func streamStartsSilentUntilItsPresentationTime() async throws {
        let rig = try StreamRig()
        try rig.player.beginStream(rig.format)
        rig.append(10, from: 100_000, hz: 441, amplitude: 0.5)
        try await rig.render(blocks: 16)
        let first = try #require(rig.left.firstIndex { $0 != 0 })
        #expect(abs(first - 4_410) <= 512)
        rig.player.endStream()
    }

    @Test func clearDropsScheduledAudioAndReanchors() async throws {
        let rig = try StreamRig()
        try rig.player.beginStream(rig.format)
        rig.append(20, hz: 441, amplitude: 0.5)   // 400 ms
        try await rig.render(blocks: 9)
        #expect(rig.left.suffix(512).contains { $0 != 0 })
        rig.player.clearStream()
        #expect(rig.player.isStreaming)
        #expect(rig.player.state == .playing)
        let cleared = rig.left.count
        try await rig.render(blocks: 4)
        // The rest of the 400 ms was dropped (the first block after the stop may still carry its tail).
        #expect(rig.left[(cleared + 512)...].allSatisfy { abs($0) < 1e-4 })

        let stamp = rig.nowMicros + 50_000
        let expected = Int((Double(stamp) / 1e6 * StreamRig.rate).rounded())
        rig.append(5, from: stamp, hz: 441, amplitude: 0.5)
        try await rig.render(blocks: 12)
        let resumed = try #require(rig.left[(cleared + 4 * 512)...].firstIndex { abs($0) > 1e-3 })
        #expect(abs(resumed - expected) <= 512)
        rig.player.endStream()
    }

    @Test func endStreamStopsAndKeepsTheLocalQueue() async throws {
        let rig = try StreamRig()
        let tracks = makeTracks(3)
        rig.player.enqueue(tracks)
        let before = rig.player.queue
        try rig.player.beginStream(rig.format)
        rig.append(5)
        try await rig.render(blocks: 4)
        rig.player.endStream()
        #expect(rig.player.state == .stopped)
        #expect(!rig.player.isStreaming)
        #expect(rig.player.queue.tracks.map(\.id) == before.tracks.map(\.id))
        #expect(rig.player.queue.currentIndex == before.currentIndex)
        #expect(rig.log.events == ["started", "ended"])
    }

    @Test func localPlayDuringAStreamPreemptsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.wav")
        try GaplessRenderTests.writeSine(to: url, hz: 441)
        let rig = try StreamRig()
        rig.player.enqueue([try Track.file(at: url)])
        try rig.player.beginStream(rig.format)
        rig.append(5)
        try await rig.render(blocks: 2)
        rig.player.play(at: 0)
        #expect(rig.log.events == ["started", "ended", "preempted"])
        #expect(!rig.player.isStreaming)
        #expect(await waitUntil { rig.player.state == .playing })
        #expect(rig.player.currentFormat?.sampleRate == GaplessRenderTests.rate)
        rig.player.stop()
    }

    @Test func beginStreamInvalidatesTheFileSchedule() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.wav")
        try GaplessRenderTests.writeSine(to: url, hz: 441)
        let rig = try StreamRig()
        rig.player.recordsDiagnostics = true
        rig.player.enqueue([try Track.file(at: url)])
        rig.player.play()
        #expect(await waitUntil { rig.player.state == .playing })
        let token = try #require(rig.player.scheduler.items.first?.token)
        try rig.player.beginStream(rig.format)
        rig.player.segmentFinished(token)
        #expect(rig.player.completionDiagnostics.last == .stale)
        #expect(rig.player.isStreaming)
        #expect(rig.player.queue.current != nil)   // the local queue is kept
        rig.player.endStream()
    }

    @Test func volumeAndBalanceApplyToTheStream() async throws {
        let full = try await renderedRMS { _ in }
        let half = try await renderedRMS { $0.volume = 0.5 }
        #expect(abs(half.left / full.left - 0.5) < 0.05)
        let panned = try await renderedRMS { $0.balance = -1 }
        #expect(panned.left > 0.03)
        #expect(panned.right < full.right * 0.05)
    }

    @Test func underrunReanchorsTheNextChunkAtItsPresentationTime() async throws {
        let rig = try StreamRig()
        try rig.player.beginStream(rig.format)
        rig.append(5, hz: 441, amplitude: 0.5)   // 100 ms
        try await rig.render(blocks: 20)          // runs dry at ~4 410 frames
        let now = rig.nowMicros
        let nowFrame = Int((Double(now) / 1e6 * StreamRig.rate).rounded())
        rig.append(15, from: 100_000, hz: 441, amplitude: 0.5, firstIndex: 5)
        #expect(rig.player.stream?.underruns == 1)
        try await rig.render(blocks: Int(0.4 * StreamRig.rate) / 512 + 4 - 20)
        let last = try #require(rig.left.lastIndex { abs($0) > 1e-3 })   // past the filters' decaying tail
        #expect(abs(last - Int(0.4 * StreamRig.rate)) <= 512)
        let resumed = try #require(rig.left[10_240...].firstIndex { abs($0) > 1e-3 })
        #expect(abs(resumed - nowFrame) <= 512)
        rig.player.endStream()
    }

    @Test func longGapIsReanchoredWithoutASilenceBuffer() async throws {
        let rig = try StreamRig()
        try rig.player.beginStream(rig.format)
        rig.append(5, hz: 441, amplitude: 0.5)
        rig.append(5, from: 2_000_000, hz: 441, amplitude: 0.5, firstIndex: 5)
        let session = try #require(rig.player.stream)
        #expect(session.pendingBuffers == 10)
        #expect(abs(session.scheduledNodeFrames - Int64((2.1 * StreamRig.rate).rounded())) <= 2)
        try await rig.render(blocks: Int(2.1 * StreamRig.rate) / 512 + 4)
        let firstEnd = try #require(rig.left[..<20_000].lastIndex { abs($0) > 1e-3 })
        #expect(abs(firstEnd - 4_410) <= 512)
        #expect(rig.left[5_000..<87_000].allSatisfy { abs($0) < 1e-4 })
        let onset = try #require(rig.left[5_000...].firstIndex { abs($0) > 1e-3 })
        #expect(abs(onset - 88_200) <= 512)
        #expect(rig.player.stream?.underruns == 0)
        rig.player.endStream()
    }
}
