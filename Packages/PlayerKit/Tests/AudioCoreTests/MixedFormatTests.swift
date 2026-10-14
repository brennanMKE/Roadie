import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// Whether tests may drive the real output device. Opt-in: set `AUDIOCORE_REALTIME=1`. Even then the
/// tests mute the main mixer, but starting a real-time engine still opens the output device, so the
/// default `swift test` run renders offline only and never touches the speaker.
/// False on machines without an output device (CI, VM guests) or when `AUDIOCORE_SKIP_REALTIME` is set.
enum RealtimeAudio {
    static let isAvailable: Bool = {
        let env = ProcessInfo.processInfo.environment
        guard env["AUDIOCORE_REALTIME"] == "1", env["AUDIOCORE_SKIP_REALTIME"] == nil else { return false }
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

/// Peaks per 128-frame block, per channel, plus the render-clock time of each block; written from
/// the tap's dispatch queue, read after the tap is removed.
final class PeakRecorder: @unchecked Sendable {
    struct Jump: Sendable { let expected: Int64; let actual: Int64 }

    private let lock = NSLock()
    private var left: [Float] = []
    private var right: [Float] = []
    private var starts: [Int64] = []
    private var jumps: [Jump] = []
    private var nextExpected: Int64?

    func record(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        let base: Int64? = when.isSampleTimeValid ? when.sampleTime : nil
        if let base {
            // A dropped tap buffer shortens the recording instead of adding zeros: a test-side artifact.
            if let expected = nextExpected, expected != base { jumps.append(Jump(expected: expected, actual: base)) }
            nextExpected = base + Int64(count)
        }
        var start = 0
        while start + 128 <= count {
            var l: Float = 0, r: Float = 0
            for i in start..<(start + 128) {
                l = max(l, abs(data[0][i]))
                r = max(r, abs(data[channels > 1 ? 1 : 0][i]))
            }
            left.append(l); right.append(r)
            starts.append((base ?? -1) + Int64(start))
            start += 128
        }
    }

    /// Nonisolated so the tap closure is not main-actor isolated (it runs on a dispatch queue).
    nonisolated func install(on node: AVAudioNode) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [self] buffer, when in record(buffer, when: when) }
    }

    var blocks: (left: [Float], right: [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (left, right)
    }

    /// Render-clock sample time of each block's first frame (-1 where the tap gave no valid time).
    var blockStarts: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return starts
    }

    var timeJumps: [Jump] {
        lock.lock(); defer { lock.unlock() }
        return jumps
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
    /// How one measurement ended. A `gap` fails the test at once; the other non-clean outcomes are
    /// retried (at most `maxAttempts`) because they are not the player's fault (#0055).
    enum Outcome: Equatable { case clean, dropout, tapArtifact, gap }

    struct Attempt {
        var outcome: Outcome
        var report: [String]
        var minLeadMillis: Double?
    }

    static let maxAttempts = 3
    /// One render quantum; a pre-scheduled item must be queued at least this far ahead of its start.
    static let leadFloorFrames: Int64 = 1024

    /// Four 0.5 s files in different formats must advance back to back. Three independent nets:
    /// (1) the scheduler: every completion before the last is `.advanced` (never `.reachedEnd`, which
    /// would mean the node ran dry and `startCurrentTrack()` restarted it) and every pre-schedule
    /// lead is above one render quantum; (2) the audible span is 2.0 s within 2,048 frames (an
    /// inserted gap lengthens it); (3) no silent 128-frame block inside the span. Silence that
    /// leaves (1) and (2) intact is a guest underrun (the node's file-reading thread starved on a
    /// loaded VM replaced audio with zeros; it did not insert time), classified as a dropout and
    /// retried with a fresh player. That holds even if the dropout lands on a track boundary: the
    /// span and the lead/completion checks define a gap, not the position.
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
        var attempts: [Attempt] = []
        for n in 1...Self.maxAttempts {
            let attempt = try await measure(urls: urls)
            attempts.append(attempt)
            let min = attempt.minLeadMillis.map { String(format: "%.1f ms", $0) } ?? "n/a"
            print("[#0055] attempt \(n)/\(Self.maxAttempts): \(attempt.outcome), min pre-schedule lead \(min)")
            if attempt.outcome != .clean { attempt.report.forEach { print("[#0055]   \($0)") } }
            if attempt.outcome == .clean || attempt.outcome == .gap { break }
        }
        let last = try #require(attempts.last)
        #expect(last.outcome == .clean, "no clean run in \(attempts.count) attempt(s): \(attempts.map(\.outcome))")
    }

    private func measure(urls: [URL]) async throws -> Attempt {
        let player = Player()
        player.recordsDiagnostics = true
        player.enqueue(try urls.map { try Track.file(at: $0) })
        player.volume = 0 // silent: the recorder taps the EQ output, upstream of the muted mixer
        let graph = player.ensureGraph()
        let eqNode = graph.eq
        let recorder = PeakRecorder()
        recorder.install(on: eqNode)

        player.play()
        #expect(await MixedFormatSupport.waitUntil(timeout: 500) { player.state == .playing })
        // Only meaningful once the engine has started and the graph is connected.
        let outputRate = try #require(player.ensureGraph().processingSampleRate)
        var indices: [Int] = []
        var lastTime: [Int: TimeInterval] = [:]
        var monotonic = true
        var inRange = true
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if player.state == .stopped { break }
            let idx = player.queue.currentIndex ?? -1
            if indices.last != idx { indices.append(idx) }
            let t = player.currentTime
            if let prev = lastTime[idx], t < prev - 0.001 { monotonic = false }
            if t > 0.5 + 0.05 { inRange = false }
            lastTime[idx] = t
            try? await Task.sleep(for: .milliseconds(10))
        }
        let stoppedBeforeDeadline = player.state == .stopped
        // The tap delivers a little behind the render thread; wait until it has drained (the block
        // count is unchanged across two consecutive 50 ms samples) instead of guessing a delay.
        var previousCount = -1
        let drainDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < drainDeadline {
            let count = recorder.blocks.left.count
            if count == previousCount { break }
            previousCount = count
            try? await Task.sleep(for: .milliseconds(50))
        }
        eqNode.removeTap(onBus: 0)
        #expect(stoppedBeforeDeadline)
        #expect(player.state == .stopped)
        #expect(player.errorMessage == nil)
        #expect(indices == [0, 1, 2, 3])
        #expect(monotonic)
        #expect(inRange)

        // Net 1: the scheduler's own record.
        let completions = player.completionDiagnostics
        let schedules = player.scheduleDiagnostics
        var schedulerOK = true
        var report: [String] = []
        let leads = schedules.filter { $0.startFrame > 0 }.compactMap { $0.leadFrames }
        let leadsMs = schedules.filter { $0.startFrame > 0 }.compactMap { $0.leadMillis }
        let completionsOK = completions.count == 4
            && completions.dropLast().allSatisfy { if case .advanced = $0 { true } else { false } }
            && completions.last == .reachedEnd
        if !completionsOK { schedulerOK = false }
        if leads.contains(where: { $0 < Self.leadFloorFrames }) { schedulerOK = false }
        if schedules.filter({ $0.startFrame > 0 }).count != 3 { schedulerOK = false }
        #expect(completionsOK, "completions before the last must be .advanced, the last .reachedEnd: \(completions)")
        #expect(
            !leads.contains(where: { $0 < Self.leadFloorFrames }),
            "a pre-schedule lead fell below \(Self.leadFloorFrames) frames: \(leadsMs) ms")
        #expect(schedules.filter { $0.startFrame > 0 }.count == 3, "expected 3 pre-schedules, saw \(schedules.count - 1)")
        report.append("completions: \(completions)")
        report.append("pre-schedule leads (ms): \(leadsMs.map { String(format: "%.1f", $0) })")

        // Nets 2 and 3: the recording.
        let blocks = recorder.blocks
        let starts = recorder.blockStarts
        let t = Self.threshold
        let first = try #require(blocks.left.firstIndex { $0 > t })
        let last = try #require(blocks.left.lastIndex { $0 > t })
        let audible = Double((last - first + 1) * 128)
        let spanDelta = audible - 2.0 * outputRate
        let spanOK = abs(spanDelta) <= 2048
        #expect(spanOK, "audible span is \(Int(spanDelta)) frames from 2.0 s")
        let jumps = recorder.timeJumps

        var zeroRuns: [(start: Int, length: Int)] = []
        var runStart: Int?
        for i in first...last {
            let silent = blocks.left[i] <= t || blocks.right[i] <= t
            if silent, runStart == nil { runStart = i }
            if !silent, let s = runStart { zeroRuns.append((s, i - s)); runStart = nil }
        }
        report.append("rate \(Int(outputRate)), span \(Int(audible)) frames (\(Int(spanDelta)) from 2.0 s)")
        for run in zeroRuns.prefix(6) {
            let sec = Double((run.start - first) * 128) / outputRate
            let nearest = (sec / 0.5).rounded() * 0.5
            let clock = starts[run.start]
            report.append(
                "zero run: \(run.length) blocks at +\(String(format: "%.3f", sec)) s (render clock \(clock)), "
                + "\(String(format: "%.1f", (sec - nearest) * 1000)) ms from the \(nearest) s boundary")
        }
        if !jumps.isEmpty { report.append("tap time jumps: \(jumps.prefix(4).map { "\($0.expected)->\($0.actual)" })") }

        let outcome: Outcome
        if zeroRuns.isEmpty && spanOK && schedulerOK {
            outcome = .clean
        } else if !schedulerOK || !spanOK {
            outcome = .gap
        } else if !jumps.isEmpty {
            outcome = .tapArtifact
        } else {
            outcome = .dropout
        }
        if outcome == .dropout || outcome == .tapArtifact {
            report.append("silence replaced audio (span, completions and leads intact): not a scheduling gap")
        }
        if outcome == .gap && !zeroRuns.isEmpty { Issue.record("silent blocks inside the audible span with a scheduler or span failure") }
        player.stop()
        return Attempt(outcome: outcome, report: report, minLeadMillis: leadsMs.min())
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
        player.volume = 0 // silent
        player.play()
        #expect(await MixedFormatSupport.waitUntil { player.state == .playing })
        player.seek(to: 0.6)
        #expect(player.currentTime == 0.6)
        // `currentTime` is refreshed by a 100 ms timer and the engine restarts after a seek, so poll
        // against a deadline instead of sleeping a fixed time; bound the result by measured elapsed time.
        let seekStart = ContinuousClock.now
        var minimum = player.currentTime
        let advanced = await waitUntil(timeoutMillis: 2000) {
            minimum = min(minimum, player.currentTime)
            return player.currentTime > 0.65
        }
        let current = player.currentTime
        let elapsed = seekStart.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(advanced)
        #expect(minimum >= 0.6)
        #expect(current <= 0.6 + elapsedSeconds + 0.05)
        #expect(current < 1.0)
        #expect(player.queue.currentIndex == 0)

        #expect(await MixedFormatSupport.waitUntil(timeout: 300) { player.queue.currentIndex == 1 })
        #expect(player.currentTime < 0.5)
        #expect(await MixedFormatSupport.waitUntil(timeout: 300) { player.state == .stopped })
        #expect(player.errorMessage == nil)
    }
}
