import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// Drives a real `Player` through AVAudioEngine's offline manual-rendering mode (no output device).
@MainActor
@Suite struct GaplessRenderTests {
    static let rate = 44100.0
    static let frames = 22050

    static func writeSine(to url: URL, hz: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            let data = buffer.floatChannelData![ch]
            for i in 0..<frames { data[i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / rate)) }
        }
        try file.write(from: buffer)
    }

    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func consecutiveFilesRenderWithoutSilentGap() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gapless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = [dir.appending(path: "a.wav"), dir.appending(path: "b.wav")]
        try Self.writeSine(to: urls[0], hz: 441)
        try Self.writeSine(to: urls[1], hz: 882)

        let player = Player()
        player.enqueue(try urls.map { try Track.file(at: $0) })
        let engine = player.ensureGraph().engine
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 512)
        player.play()

        #expect(await waitUntil { player.hasPreScheduledNext })

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var peaks: [Float] = []
        var total = 0
        // The node reads its schedule ahead of real time; render until both files are well past.
        while total < Self.frames * 2 + 4096 {
            let status = try engine.renderOffline(512, to: out)
            #expect(status == .success)
            let data = out.floatChannelData![0]
            var peak: Float = 0
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(data[i])) }
            peaks.append(peak)
            total += Int(out.frameLength)
            if total % 4096 == 0 { await Task.yield() }
        }

        // Locate the audible span and require every block inside it to carry signal.
        let first = try #require(peaks.firstIndex { $0 > 0.01 })
        let last = try #require(peaks.lastIndex { $0 > 0.01 })
        let audibleFrames = (last - first + 1) * 512
        #expect(audibleFrames >= Self.frames * 2 - 1024)
        #expect(audibleFrames <= Self.frames * 2 + 1024)
        let silentBlocks = peaks[first...last].filter { $0 <= 0.01 }.count
        #expect(silentBlocks == 0)

        // Completion callbacks are not delivered in offline mode; promotion is covered by the pure tests.
        player.stop()
    }
}
