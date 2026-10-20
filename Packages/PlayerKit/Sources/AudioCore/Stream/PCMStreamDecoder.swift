import AVFoundation

/// Turns interleaved little-endian integer PCM into buffers in the graph's processing format (Float32,
/// non-interleaved, stereo, the node rate). A resampler, when the rates differ, is kept across chunks so its
/// state stays continuous; `reset()` drops it (stream/clear, a re-anchor).
struct PCMStreamDecoder {
    let format: StreamFormat
    let nodeRate: Double
    let sourceFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init?(format: StreamFormat, nodeRate: Double) {
        guard format.sampleRate > 0, format.channels > 0, [16, 24, 32].contains(format.bitDepth),
              let source = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2),
              let output = AVAudioFormat(standardFormatWithSampleRate: nodeRate, channels: 2) else { return nil }
        self.format = format
        self.nodeRate = nodeRate
        sourceFormat = source
        outputFormat = output
        converter = Self.makeConverter(from: source, to: output)
    }

    private static func makeConverter(from source: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
        guard source.sampleRate != output.sampleRate,
              let converter = AVAudioConverter(from: source, to: output) else { return nil }
        // No priming: output starts with the first input frame, so frame counts track the exact ratio.
        converter.primeMethod = .none
        return converter
    }

    var resamples: Bool { converter != nil }

    mutating func reset() {
        converter?.reset()
    }

    /// Decodes whole frames of `data`, dropping `dropLeading` frames at the start and repeating the last frame
    /// `duplicateLast` more times (sync corrections, applied at the source rate). nil when nothing is left.
    mutating func decode(_ data: Data, dropLeading: Int = 0, duplicateLast: Int = 0) -> AVAudioPCMBuffer? {
        let total = format.frameCount(of: data)
        let drop = min(max(dropLeading, 0), total)
        let kept = total - drop
        guard kept > 0 else { return nil }
        let frames = kept + max(duplicateLast, 0)
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channels = source.floatChannelData else { return nil }
        source.frameLength = AVAudioFrameCount(frames)
        let left = channels[0]
        let right = channels[1]
        let bytesPerSample = format.bitDepth / 8
        let stride = format.bytesPerFrame
        let channelCount = format.channels
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func sample(_ frame: Int, _ channel: Int) -> Float {
                let offset = frame * stride + channel * bytesPerSample
                switch bytesPerSample {
                case 2:
                    let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                    return Float(v) / 32_768
                case 3:
                    let u = UInt32(raw[offset]) | UInt32(raw[offset + 1]) << 8 | UInt32(raw[offset + 2]) << 16
                    let v = Int32(bitPattern: u << 8) >> 8
                    return Float(v) / 8_388_608
                default:
                    let v = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))
                    return Float(Double(v) / 2_147_483_648)
                }
            }
            for i in 0..<kept {
                let frame = drop + i
                let l = sample(frame, 0)
                left[i] = l
                right[i] = channelCount >= 2 ? sample(frame, 1) : l
            }
        }
        if frames > kept {
            for i in kept..<frames {
                left[i] = left[kept - 1]
                right[i] = right[kept - 1]
            }
        }
        guard let converter else { return source }
        let ratio = nodeRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = source
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return output.frameLength > 0 ? output : nil
    }
}
