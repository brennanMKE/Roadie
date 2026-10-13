import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// Whether tests may drive the real output device. False on machines without one (CI, VM guests)
/// or when `AUDIOCORE_SKIP_REALTIME` is set.
enum RealtimeAudio {
    static let isAvailable: Bool = {
        if ProcessInfo.processInfo.environment["AUDIOCORE_SKIP_REALTIME"] != nil { return false }
        let engine = AVAudioEngine()
        guard engine.outputNode.outputFormat(forBus: 0).sampleRate > 0 else { return false }
        _ = engine.mainMixerNode
        do {
            try engine.start()
            engine.stop()
            return true
        } catch {
            return false
        }
    }()
}

enum MixedFormatSupport {
    static func writeSine(
        to url: URL, rate: Double, channels: AVAudioChannelCount, seconds: Double, hz: Double = 441, amplitude: Float = 0.5
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = Int(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<frames { data[i] = amplitude * Float(sin(2 * .pi * hz * Double(i) / rate)) }
        }
        try file.write(from: buffer)
    }

    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func waitUntil(timeout: Int = 500, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<timeout {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

/// Peaks per 128-frame block, per channel; written from the audio thread, read after the tap is removed.
final class PeakRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [Float] = []
    private var right: [Float] = []

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        var start = 0
        while start + 128 <= count {
            var l: Float = 0, r: Float = 0
            for i in start..<(start + 128) {
                l = max(l, abs(data[0][i]))
                r = max(r, abs(data[channels > 1 ? 1 : 0][i]))
            }
            left.append(l); right.append(r)
            start += 128
        }
    }

    /// Nonisolated so the tap closure is not main-actor isolated (it runs on a dispatch queue).
    nonisolated func install(on mixer: AVAudioMixerNode) {
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [self] buffer, _ in record(buffer) }
    }

    var blocks: (left: [Float], right: [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (left, right)
    }
}

@MainActor
@Suite struct MixedFormatTests {
    static let threshold: Float = 0.005

    @Test func mixedFormatsRenderOffline() async throws {
        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let specs: [(rate: Double, channels: AVAudioChannelCount)] = [(44100, 2), (48000, 2), (44100, 1)]
        var urls: [URL] = []
        for (i, spec) in specs.enumerated() {
            let url = dir.appending(path: "f\(i).wav")
            try MixedFormatSupport.writeSine(to: url, rate: spec.rate, channels: spec.channels, seconds: 0.5)
            urls.append(url)
        }

        let player = Player()
        player.enqueue(try urls.map { try Track.file(at: $0) })
        let engine = player.ensureGraph().engine
        try engine.enableManualRenderingMode(
            .offline, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!, maximumFrameCount: 512)
        player.play()
        #expect(await MixedFormatSupport.waitUntil { player.hasPreScheduledNext })
        #expect(player.errorMessage == nil)

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var left: [Float] = [], right: [Float] = []
        var total = 0
        // Only the current and one pre-scheduled file are on the node in offline mode (no completions).
        while total < 44100 * 2 {
            #expect(try engine.renderOffline(512, to: out) == .success)
            var l: Float = 0, r: Float = 0
            for i in 0..<Int(out.frameLength) {
                l = max(l, abs(out.floatChannelData![0][i]))
                r = max(r, abs(out.floatChannelData![1][i]))
            }
            left.append(l); right.append(r)
            total += Int(out.frameLength)
            if total % 4096 == 0 { await Task.yield() }
        }
        let first = try #require(left.firstIndex { $0 > Self.threshold })
        let last = try #require(left.lastIndex { $0 > Self.threshold })
        let audible = (last - first + 1) * 512
        #expect(audible >= 44100 - 1024 && audible <= 44100 + 1024)
        #expect(left[first...last].filter { $0 <= Self.threshold }.isEmpty)
        #expect(right[first...last].filter { $0 <= Self.threshold }.isEmpty)
        player.stop()

        // Mono source reaches both channels.
        let mono = Player()
        mono.enqueue([try Track.file(at: urls[2])])
        let monoEngine = mono.ensureGraph().engine
        try monoEngine.enableManualRenderingMode(
            .offline, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!, maximumFrameCount: 512)
        mono.play()
        #expect(await MixedFormatSupport.waitUntil { mono.state == .playing })
        var rightPeak: Float = 0
        let monoOut = AVAudioPCMBuffer(pcmFormat: monoEngine.manualRenderingFormat, frameCapacity: 512)!
        for _ in 0..<20 {
            _ = try monoEngine.renderOffline(512, to: monoOut)
            for i in 0..<Int(monoOut.frameLength) { rightPeak = max(rightPeak, abs(monoOut.floatChannelData![1][i])) }
        }
        #expect(rightPeak > 0.01)
        mono.stop()
    }

    @Test func outputRateChangeReconnectsWhileStopped() async throws {
        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for i in 0..<2 {
            let url = dir.appending(path: "f\(i).wav")
            try MixedFormatSupport.writeSine(to: url, rate: 44100, channels: 2, seconds: 1.0)
            urls.append(url)
        }
        let player = Player()
        player.enqueue(try urls.map { try Track.file(at: $0) })
        let graph = player.ensureGraph()
        let engine = graph.engine
        try engine.enableManualRenderingMode(
            .offline, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!, maximumFrameCount: 512)
        player.play()
        #expect(await MixedFormatSupport.waitUntil { player.hasPreScheduledNext })
        #expect(graph.processingSampleRate == 44100)

        let out44 = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        for _ in 0..<40 { _ = try engine.renderOffline(512, to: out44) }

        engine.stop()
        try engine.enableManualRenderingMode(
            .offline, format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!, maximumFrameCount: 512)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)

        #expect(await MixedFormatSupport.waitUntil { player.hasPreScheduledNext && graph.processingSampleRate == 48000 })
        #expect(graph.processingSampleRate == 48000)
        #expect(engine.isRunning)
        #expect(player.state == .playing)
        #expect(player.errorMessage == nil)

        let out48 = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var peak: Float = 0
        for _ in 0..<40 {
            _ = try engine.renderOffline(512, to: out48)
            for i in 0..<Int(out48.frameLength) { peak = max(peak, abs(out48.floatChannelData![0][i])) }
        }
        #expect(peak > 0.01)
        player.stop()
    }
}

@MainActor
@Suite(.serialized) struct MixedFormatRealtimeTests {
    @Test(.enabled(if: RealtimeAudio.isAvailable))
    func mixedFormatsAdvanceWithoutGapRealtime() async throws {
        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let specs: [(rate: Double, channels: AVAudioChannelCount)] = [(44100, 2), (48000, 2), (44100, 1), (96000, 2)]
        var urls: [URL] = []
        for (i, spec) in specs.enumerated() {
            let url = dir.appending(path: "f\(i).wav")
            try MixedFormatSupport.writeSine(
                to: url, rate: spec.rate, channels: spec.channels, seconds: 0.5, amplitude: 0.05)
            urls.append(url)
        }
        let player = Player()
        player.enqueue(try urls.map { try Track.file(at: $0) })
        let mixer = player.ensureGraph().mainMixerNode
        let recorder = PeakRecorder()
        recorder.install(on: mixer)

        player.play()
        #expect(await MixedFormatSupport.waitUntil(timeout: 500) { player.state == .playing })
        // Only meaningful once the engine has started and the graph is connected.
        let outputRate = try #require(player.ensureGraph().processingSampleRate)
        var indices: [Int] = []
        var lastTime: [Int: TimeInterval] = [:]
        var monotonic = true
        var inRange = true
        for _ in 0..<600 {
            if player.state == .stopped { break }
            let idx = player.queue.currentIndex ?? -1
            if indices.last != idx { indices.append(idx) }
            let t = player.currentTime
            if let prev = lastTime[idx], t < prev - 0.001 { monotonic = false }
            if t > 0.5 + 0.05 { inRange = false }
            lastTime[idx] = t
            try? await Task.sleep(for: .milliseconds(10))
        }
        // The tap delivers a little behind the render thread; let the last buffers arrive.
        try? await Task.sleep(for: .milliseconds(200))
        mixer.removeTap(onBus: 0)
        #expect(player.state == .stopped)
        #expect(player.errorMessage == nil)
        #expect(indices == [0, 1, 2, 3])
        #expect(monotonic)
        #expect(inRange)

        let blocks = recorder.blocks
        let t = Self.threshold
        let first = try #require(blocks.left.firstIndex { $0 > t })
        let last = try #require(blocks.left.lastIndex { $0 > t })
        #expect(blocks.left[first...last].filter { $0 <= t }.isEmpty)
        #expect(blocks.right[first...last].filter { $0 <= t }.isEmpty)
        let audible = Double((last - first + 1) * 128)
        #expect(abs(audible - 2.0 * outputRate) <= 2048)
    }

    static let threshold: Float = 0.002

    @Test(.enabled(if: RealtimeAudio.isAvailable))
    func seekInResampledFileKeepsFileTime() async throws {
        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.wav"), b = dir.appending(path: "b.wav")
        try MixedFormatSupport.writeSine(to: a, rate: 44100, channels: 2, seconds: 1.0, amplitude: 0.05)
        try MixedFormatSupport.writeSine(to: b, rate: 48000, channels: 2, seconds: 0.5, amplitude: 0.05)
        let player = Player()
        player.enqueue([try Track.file(at: a), try Track.file(at: b)])
        player.play()
        #expect(await MixedFormatSupport.waitUntil { player.state == .playing })
        player.seek(to: 0.6)
        #expect(player.currentTime == 0.6)
        try await Task.sleep(for: .milliseconds(200))
        #expect((0.7...0.9).contains(player.currentTime))

        #expect(await MixedFormatSupport.waitUntil(timeout: 300) { player.queue.currentIndex == 1 })
        #expect(player.currentTime < 0.3)
        #expect(await MixedFormatSupport.waitUntil(timeout: 300) { player.state == .stopped })
        #expect(player.errorMessage == nil)
    }
}
