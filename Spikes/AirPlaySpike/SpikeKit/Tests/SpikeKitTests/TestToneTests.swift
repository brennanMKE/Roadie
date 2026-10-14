import AVFoundation
import Testing
@testable import SpikeKit

@Suite struct TestToneTests {
    @Test func writesTicksOnIntegerSeconds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TestToneTests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("tick.wav")
        try TestTone.write(to: url, seconds: 3, rate: 48_000)
        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 2)
        #expect(file.length == 3 * 48_000)

        func peaks(from second: Int, frames: Int) throws -> (Float, Float) {
            file.framePosition = AVAudioFramePosition(second * 48_000)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
            try file.read(into: buf, frameCount: AVAudioFrameCount(frames))
            let l = (0..<Int(buf.frameLength)).map { abs(buf.floatChannelData![0][$0]) }.max() ?? 0
            let r = (0..<Int(buf.frameLength)).map { abs(buf.floatChannelData![1][$0]) }.max() ?? 0
            return (l, r)
        }
        for second in [1, 2] {
            let (l, r) = try peaks(from: second, frames: 960)
            #expect(l > 0.5)
            #expect(r < 0.2)
        }
        // Between ticks the left channel is just the quiet tone.
        let (quietL, _) = try peaks(from: 1, frames: 960)
        file.framePosition = 48_000 + 24_000
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 960)!
        try file.read(into: buf, frameCount: 960)
        let mid = (0..<Int(buf.frameLength)).map { abs(buf.floatChannelData![0][$0]) }.max() ?? 1
        #expect(mid < 0.2)
        #expect(quietL > mid)
    }
}
