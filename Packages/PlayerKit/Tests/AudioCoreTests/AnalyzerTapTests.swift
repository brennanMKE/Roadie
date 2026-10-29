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

    // MARK: Stereo ring (#0232)

    private static func latest(_ ring: VisSampleRing, _ count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        let ok = out.withUnsafeMutableBufferPointer { ring.copyLatest(count: count, into: $0.baseAddress!) }
        #expect(ok)
        return out
    }

    @Test func stereoIsOffByDefaultAndWritesNothing() {
        let tap = AnalyzerTap()
        tap.prepare(sampleRate: 48_000)
        #expect(!tap.isStereoEnabled)
        tap.deliver(TapBuffers.make(frames: 512, channels: 2) { c, _ in c == 0 ? 0.25 : -0.5 })
        #expect(tap.stereo.writeCount == 0)
        #expect(tap.ring.writeCount == 512)
    }

    @Test func stereoInterleavesLeftAndRight() {
        let tap = AnalyzerTap()
        tap.prepare(sampleRate: 48_000)
        tap.setStereoEnabled(true)
        #expect(tap.isStereoEnabled)
        tap.deliver(TapBuffers.make(frames: 512, channels: 2) { c, _ in c == 0 ? 0.25 : -0.5 })
        #expect(tap.stereo.writeCount == 1_024)
        let s = Self.latest(tap.stereo, 1_024)
        for i in 0..<512 {
            #expect(s[2 * i] == 0.25)
            #expect(s[2 * i + 1] == -0.5)
        }
    }

    @Test func monoSourceIsDuplicatedIntoBothChannels() {
        let tap = AnalyzerTap()
        tap.prepare(sampleRate: 48_000)
        tap.setStereoEnabled(true)
        tap.deliver(TapBuffers.make(frames: 300, channels: 1) { _, i in Float(i) })
        let s = Self.latest(tap.stereo, 600)
        for i in 0..<300 {
            #expect(s[2 * i] == Float(i))
            #expect(s[2 * i + 1] == s[2 * i])
        }
    }

    @Test func extraChannelsAreIgnored() {
        let tap = AnalyzerTap()
        tap.prepare(sampleRate: 48_000)
        tap.setStereoEnabled(true)
        tap.deliver(TapBuffers.make(frames: 256, channels: 4) { c, _ in Float(c + 1) })
        #expect(tap.stereo.writeCount == 512)
        let s = Self.latest(tap.stereo, 512)
        for i in 0..<256 {
            #expect(s[2 * i] == 1)
            #expect(s[2 * i + 1] == 2)
        }
    }

    @Test func monoRingIsUnchangedWithStereoOn() {
        let off = AnalyzerTap(), on = AnalyzerTap()
        off.prepare(sampleRate: 48_000); on.prepare(sampleRate: 48_000)
        on.setStereoEnabled(true)
        for k in 0..<5 {
            let buffer = TapBuffers.make(frames: 1_000 + 37 * k, channels: 2) { c, i in
                c == 0 ? Float(sin(Double(i) * 0.01)) : Float(i % 97) / 97
            }
            off.deliver(buffer); on.deliver(buffer)
        }
        #expect(on.ring.writeCount == off.ring.writeCount)
        #expect(Self.latest(on.ring, 4_096) == Self.latest(off.ring, 4_096))
    }

    @Test func stereoWritesWholeFramesAcrossChunkBoundaries() {
        let tap = AnalyzerTap()
        tap.prepare(sampleRate: 48_000)
        tap.setStereoEnabled(true)
        let a = TapBuffers.make(frames: 4_801, channels: 2) { c, _ in c == 0 ? 0.25 : -0.5 }
        let b = TapBuffers.make(frames: 4_799, channels: 2) { c, _ in c == 0 ? 0.25 : -0.5 }
        for k in 0..<60 {
            tap.deliver(k % 2 == 0 ? a : b)
            #expect(tap.stereo.writeCount % 2 == 0)
            let s = Self.latest(tap.stereo, 2_048)
            #expect(s[0] == 0.25)
            #expect(zip(s, s.dropFirst()).allSatisfy { $0 != $1 })
        }
        #expect(tap.stereo.writeCount > 10 * tap.stereo.capacity)
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
