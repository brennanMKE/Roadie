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
        #expect(await waitUntil { player.state == .playing && player.analyzer.isInstalled })

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        for i in 0..<40 {
            _ = try engine.renderOffline(512, to: out)
            if i % 8 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(await waitUntil { player.analyzer.latestFrame() != nil })

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

    @Test func frameElapsedAdvancesThroughBurstDeliveries() throws {
        let tap = AnalyzerTap()
        tap.prepare(sampleRate: 48_000)
        // 1500 Hz = bin 32 of a 1024-point FFT at 48 kHz, phase-continuous across bursts.
        let hz = 32 * 48_000.0 / 1024
        var phase = 0
        var frames: [VisFrame] = []
        for tick in 0..<240 {
            if tick % 6 == 0 {
                let burst = (0..<4800).map { Float(0.8 * sin(2 * Double.pi * hz * Double(phase + $0) / 48_000)) }
                phase += 4800
                burst.withUnsafeBufferPointer { tap.ring.write($0.baseAddress!, count: 4800) }
            }
            if let frame = tap.frame(elapsed: 1.0 / 60) { frames.append(frame) }
        }
        let steady = frames.suffix(120)
        let map = try #require(tap.columnMap)
        var previous: Int?
        for frame in steady {
            if let previous { #expect((799...801).contains(frame.sampleCount - previous)) }
            previous = frame.sampleCount
            let peak = frame.spectrum.firstIndex(of: frame.spectrum.max()!)!
            #expect(map.ranges[peak].contains(map.bin(forFrequency: hz)))
        }
    }

    private static func offlineEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        _ = engine.mainMixerNode
        try engine.start()
        return engine
    }

    @Test func theTapBlockDoesNotKeepTheAnalyzerAlive() throws {
        let engine = try Self.offlineEngine()
        defer { engine.stop() }
        weak var weakTap: AnalyzerTap?
        do {
            let tap = AnalyzerTap()
            tap.install(on: engine.mainMixerNode, sampleRate: 44_100)
            #expect(tap.isInstalled)
            weakTap = tap
        }
        #expect(weakTap == nil)
    }

    @Test func removingTheTapAfterItsNodeWasDetachedDoesNotRaise() throws {
        let engine = try Self.offlineEngine()
        defer { engine.stop() }
        let node = AVAudioMixerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        var tap: AnalyzerTap? = AnalyzerTap()
        tap?.install(on: node, sampleRate: 44_100)
        engine.detach(node)
        tap?.remove()
        #expect(tap?.isInstalled == false)
        tap = nil
        withExtendedLifetime(node) {}
    }

    @Test func releasingTheTapAfterItsEngineIsGoneDoesNotRaise() throws {
        let tap = AnalyzerTap()
        let node: AVAudioNode
        do {
            let engine = try Self.offlineEngine()
            node = engine.mainMixerNode
            tap.install(on: node, sampleRate: 44_100)
            engine.stop()
        }
        tap.remove()
        #expect(!tap.isInstalled)
        withExtendedLifetime(node) {}
    }
}
