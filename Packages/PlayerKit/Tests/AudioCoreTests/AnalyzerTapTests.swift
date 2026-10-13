import AVFoundation
import Foundation
import Testing
@testable import AudioCore

@MainActor
@Suite struct AnalyzerTapTests {
    @Test func tapDeliversFramesThroughOfflineRender() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "analyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "tone.wav")
        // 1378.125 Hz = bin 32 of a 1024-point FFT at 44.1 kHz.
        let hz = 32 * 44_100.0 / 1024
        try GaplessRenderTests.writeSine(to: url, hz: hz)

        let player = Player()
        player.enqueue([try Track.file(at: url)])
        let graph = player.ensureGraph()
        let engine = graph.engine
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        player.play()
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.analyzer.isInstalled)

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        for i in 0..<40 {
            _ = try engine.renderOffline(512, to: out)
            if i % 8 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        try await Task.sleep(for: .milliseconds(200))

        let frame = try #require(player.analyzer.latestFrame())
        let map = try #require(player.analyzer.columnMap)
        let peak = frame.spectrum.firstIndex(of: frame.spectrum.max()!)!
        #expect(frame.spectrum.max()! > 0.5)
        #expect(map.ranges[peak].contains(map.bin(forFrequency: hz)))
        #expect(frame.scope.count == 76)

        // Restart path: starting again must not double-install (that raises an uncatchable exception).
        player.analyzer.install(on: graph.mainMixerNode, sampleRate: 44_100)
        player.analyzer.install(on: graph.mainMixerNode, sampleRate: 44_100)
        #expect(player.analyzer.isInstalled)
        player.stop()
        player.analyzer.remove()
        #expect(!player.analyzer.isInstalled)
    }
}
