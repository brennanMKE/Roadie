import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// Little-endian 16-bit interleaved PCM from integer samples.
func pcm16(_ samples: [Int16]) -> Data {
    var data = Data()
    for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
    return data
}

/// 16-bit stereo sine PCM, `frames` frames starting at `startFrame`.
func sinePCM16(hz: Double, amplitude: Double, frames: Int, startFrame: Int = 0, rate: Double) -> Data {
    var samples: [Int16] = []
    samples.reserveCapacity(frames * 2)
    for i in 0..<frames {
        let v = Int16((amplitude * sin(2 * .pi * hz * Double(startFrame + i) / rate) * 32_767).rounded())
        samples.append(v)
        samples.append(v)
    }
    return pcm16(samples)
}

@Suite struct PCMStreamDecoderTests {
    func channel(_ buffer: AVAudioPCMBuffer, _ ch: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(buffer.frameLength)))
    }

    @Test func decodes16BitLittleEndianInterleaved() throws {
        var decoder = try #require(PCMStreamDecoder(
            format: StreamFormat(sampleRate: 44_100, channels: 2, bitDepth: 16), nodeRate: 44_100))
        let decoded = decoder.decode(pcm16([16_384, -32_768, -16_384, 0]))
        let buffer = try #require(decoded)
        #expect(buffer.frameLength == 2)
        #expect(channel(buffer, 0) == [0.5, -0.5])
        #expect(channel(buffer, 1) == [-1.0, 0])
    }

    @Test func decodes24BitPackedWithSign() throws {
        var decoder = try #require(PCMStreamDecoder(
            format: StreamFormat(sampleRate: 48_000, channels: 2, bitDepth: 24), nodeRate: 48_000))
        let bytes: [UInt8] = [0x00, 0x00, 0x40, 0x00, 0x00, 0x80,   // 0.5, -1
                              0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00]   // -1 LSB, +1 LSB
        let decoded = decoder.decode(Data(bytes))
        let buffer = try #require(decoded)
        #expect(buffer.frameLength == 2)
        #expect(channel(buffer, 0) == [0.5, -1 / 8_388_608])
        #expect(channel(buffer, 1) == [-1.0, 1 / 8_388_608])
    }

    @Test func monoIsDuplicatedToBothChannels() throws {
        var decoder = try #require(PCMStreamDecoder(
            format: StreamFormat(sampleRate: 44_100, channels: 1, bitDepth: 16), nodeRate: 44_100))
        let decoded = decoder.decode(pcm16([16_384, -16_384, 8_192]))
        let buffer = try #require(decoded)
        #expect(buffer.frameLength == 3)
        #expect(channel(buffer, 0) == [0.5, -0.5, 0.25])
        #expect(channel(buffer, 1) == channel(buffer, 0))
    }

    @Test func dropAndDuplicateChangeTheFrameCountExactly() throws {
        var decoder = try #require(PCMStreamDecoder(
            format: StreamFormat(sampleRate: 44_100, channels: 2, bitDepth: 16), nodeRate: 44_100))
        let data = pcm16((0..<10).flatMap { [Int16($0 * 1000), Int16($0 * 1000)] })
        let whole = decoder.decode(data)?.frameLength
        #expect(whole == 10)
        let decoded = decoder.decode(data, dropLeading: 3, duplicateLast: 2)
        let buffer = try #require(decoded)
        #expect(buffer.frameLength == 9)
        let left = channel(buffer, 0)
        #expect(left.first == Float(3000) / 32_768)
        #expect(Array(left.suffix(3)) == Array(repeating: Float(9000) / 32_768, count: 3))
        let none = decoder.decode(data, dropLeading: 10)
        #expect(none == nil)
    }

    @Test func resamples44100To48000Continuously() throws {
        var decoder = try #require(PCMStreamDecoder(
            format: StreamFormat(sampleRate: 44_100, channels: 2, bitDepth: 16), nodeRate: 48_000))
        #expect(decoder.resamples)
        var total = 0
        for chunk in 0..<20 {
            let data = sinePCM16(hz: 441, amplitude: 0.5, frames: 441, startFrame: chunk * 441, rate: 44_100)
            if let buffer = decoder.decode(data) {
                #expect(buffer.format.sampleRate == 48_000)
                total += Int(buffer.frameLength)
            }
        }
        #expect(abs(total - 9_600) <= 2)   // 20 × 441 frames × 48 000 / 44 100
    }
}
