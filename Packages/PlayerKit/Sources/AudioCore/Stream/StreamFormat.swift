import Foundation

/// Signed little-endian interleaved PCM (16 or 24 bit packed), as Sendspin sends it.
public struct StreamFormat: Hashable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public var bitDepth: Int

    public init(sampleRate: Double, channels: Int, bitDepth: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
    }

    /// Bytes per interleaved frame (all channels).
    public var bytesPerFrame: Int { max(channels, 1) * max(bitDepth / 8, 1) }

    /// Whole frames in `pcm`; a trailing partial frame is ignored.
    public func frameCount(of pcm: Data) -> Int { pcm.count / bytesPerFrame }
}

/// One chunk: whole frames, and the local time (µs, CLOCK_UPTIME_RAW / host-time base) its first frame must be heard.
public struct StreamChunk: Sendable {
    public var presentationMicros: Int64
    public var pcm: Data

    public init(presentationMicros: Int64, pcm: Data) {
        self.presentationMicros = presentationMicros
        self.pcm = pcm
    }
}
