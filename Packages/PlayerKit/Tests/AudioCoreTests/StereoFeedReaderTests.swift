import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// Non-interleaved Float32 buffers like the engine's, for driving `AnalyzerTap.deliver`.
enum TapBuffers {
    static func make(frames: Int, channels: Int, sampleRate: Double = 48_000,
                     _ value: (_ channel: Int, _ frame: Int) -> Float) -> AVAudioPCMBuffer {
        let format: AVAudioFormat
        if channels <= 2 {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        } else {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        for c in 0..<channels {
            for i in 0..<frames { data[c][i] = value(c, i) }
        }
        return buffer
    }

    /// Left = absolute frame index, right = its negation, so contiguity and channel order are checkable.
    static func ramp(from start: Int, frames: Int, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        make(frames: frames, channels: 2, sampleRate: sampleRate) { c, i in
            let v = Float(start + i)
            return c == 0 ? v : -v
        }
    }
}

@MainActor
@Suite struct StereoFeedReaderTests {
    private func makeTap(_ rate: Double = 48_000) -> AnalyzerTap {
        let tap = AnalyzerTap()
        tap.prepare(sampleRate: rate)
        tap.setStereoEnabled(true)
        return tap
    }

    /// Checks interleaving and returns (first L, last L).
    private func span(_ r: (samples: UnsafeBufferPointer<Float>, frames: Int, sampleRate: Double)) -> (Float, Float) {
        #expect(r.samples.count == 2 * r.frames)
        for i in 0..<r.frames where r.samples[2 * i + 1] != -r.samples[2 * i] {
            Issue.record("frame \(i) is not an L R pair"); break
        }
        return (r.samples[0], r.samples[2 * (r.frames - 1)])
    }

    @Test func readerReturnsNothingBeforeAWindowHasPlayed() {
        let tap = makeTap()
        let reader = StereoFeedReader(tap: tap)
        for _ in 0..<10 { #expect(reader.read(elapsed: 1.0 / 60) == nil) }
        tap.deliver(TapBuffers.ramp(from: 0, frames: 500))
        for _ in 0..<10 { #expect(reader.read(elapsed: 1.0 / 60) == nil) }
    }

    @Test func readerPacesBurstDeliveries() {
        let tap = makeTap()
        let reader = StereoFeedReader(tap: tap)
        var written = 0
        var reads: [(count: Int, first: Float, last: Float)] = []
        for tick in 0..<240 {
            if tick % 6 == 0 {
                tap.deliver(TapBuffers.ramp(from: written, frames: 4_800))
                written += 4_800
            }
            if let r = reader.read(elapsed: 1.0 / 60) {
                let (first, last) = span(r)
                reads.append((r.frames, first, last))
            }
        }
        let steady = Array(reads.suffix(120))
        #expect(steady.count == 120)
        for (i, r) in steady.enumerated() {
            #expect((799...801).contains(r.count))
            if i > 0 { #expect(r.first == steady[i - 1].last + 1) }
        }
    }

    @Test func readerReturnsNothingWhilePaused() {
        let tap = makeTap()
        let reader = StereoFeedReader(tap: tap)
        var written = 0
        for tick in 0..<120 {
            if tick % 6 == 0 { tap.deliver(TapBuffers.ramp(from: written, frames: 4_800)); written += 4_800 }
            _ = reader.read(elapsed: 1.0 / 60)
        }
        // Paused: the buffered tail may play out, then nothing.
        for tick in 0..<120 {
            let r = reader.read(elapsed: 1.0 / 60)
            if tick >= 30 { #expect(r == nil) }
        }
        var resumed = 0
        for tick in 0..<60 {
            if tick % 6 == 0 { tap.deliver(TapBuffers.ramp(from: written, frames: 4_800)); written += 4_800 }
            if let r = reader.read(elapsed: 1.0 / 60) {
                resumed += 1
                #expect(r.frames <= StereoFeedReader.window)
            }
        }
        #expect(resumed > 0)
    }

    @Test func readerResetsWhenTheSampleRateChanges() throws {
        let tap = makeTap(44_100)
        let reader = StereoFeedReader(tap: tap)
        var written = 0
        for tick in 0..<60 {
            if tick % 6 == 0 { tap.deliver(TapBuffers.ramp(from: written, frames: 4_410, sampleRate: 44_100)); written += 4_410 }
            if let r = reader.read(elapsed: 1.0 / 60) { #expect(r.sampleRate == 44_100) }
        }
        tap.prepare(sampleRate: 48_000)
        tap.deliver(TapBuffers.ramp(from: written, frames: 4_800))
        let r = try #require(reader.read(elapsed: 1.0 / 60))
        #expect(r.sampleRate == 48_000)
        #expect(r.frames == StereoFeedReader.window)
    }

    @Test func readerCapsAStallAtMaxFrames() throws {
        let tap = makeTap()
        let reader = StereoFeedReader(tap: tap)
        var written = 0
        for tick in 0..<60 {
            if tick % 6 == 0 { tap.deliver(TapBuffers.ramp(from: written, frames: 4_800)); written += 4_800 }
            _ = reader.read(elapsed: 1.0 / 60)
        }
        for _ in 0..<20 { tap.deliver(TapBuffers.ramp(from: written, frames: 4_800)); written += 4_800 }
        let r = try #require(reader.read(elapsed: 2))
        #expect(r.frames == StereoFeedReader.maxFrames)
        let (_, last) = span(r)
        // The newest audio: within one delivery plus slack of the write head, not the stale stretch.
        #expect(Int(last) >= written - 4_800 - 2_000)
    }

    @Test func readerHasItsOwnCursor() {
        let tap = makeTap()
        let reader = StereoFeedReader(tap: tap)
        var written = 0
        var previousLast: Float?
        var reads = 0
        for tick in 0..<240 {
            if tick % 6 == 0 { tap.deliver(TapBuffers.ramp(from: written, frames: 4_800)); written += 4_800 }
            _ = tap.frame(elapsed: 1.0 / 60)
            if tick % 37 == 0 { tap.resetCursor() }
            if let r = reader.read(elapsed: 1.0 / 60) {
                let (first, last) = span(r)
                if let previousLast { #expect(first == previousLast + 1) }
                previousLast = last
                reads += 1
            }
        }
        #expect(reads > 100)
    }
}
