/// Consumer side of the stereo ring, at display rate (main actor in the app). Each `read` returns the frames that
/// played since the previous one (interleaved L R), paced by elapsed time a delivery behind the write head, so a
/// renderer fed once per tick sees smooth audio although the tap delivers ~100 ms bursts.
public final class StereoFeedReader {
    public static let maxFrames = 4_096
    /// Frames returned by the first read after a reset.
    public static let window = 1_024

    private let tap: AnalyzerTap
    private var cursor: VisReadCursor
    private var lastEnd: Int?
    private var lastRate: Double = 0
    private let buffer: UnsafeMutablePointer<Float>

    public init(tap: AnalyzerTap) {
        self.tap = tap
        let ring = tap.stereo
        cursor = VisReadCursor(window: Self.window, readable: (ring.capacity - ring.maxChunk) / 2)
        buffer = .allocate(capacity: 2 * Self.maxFrames)
        buffer.initialize(repeating: 0, count: 2 * Self.maxFrames)
    }

    deinit { buffer.deallocate() }

    /// nil until a window's worth has flowed, or when nothing new played (paused, stopped, stalled).
    /// The returned pointer is valid until the next `read`.
    public func read(elapsed dt: Double) -> (samples: UnsafeBufferPointer<Float>, frames: Int, sampleRate: Double)? {
        let rate = tap.stereoSampleRate
        if rate != lastRate {
            reset()
            lastRate = rate
        }
        guard rate > 0 else { return nil }
        let ring = tap.stereo
        guard let end = cursor.next(writeCount: ring.writeCount / 2, elapsed: dt, sampleRate: rate) else { return nil }
        if let lastEnd, end <= lastEnd { return nil }
        // A jump past maxFrames (the main thread stalled) keeps just the newest frames: re-lag, never replay.
        let count = min(end - (lastEnd ?? end - Self.window), Self.maxFrames)
        guard ring.copy(count: 2 * count, endingAt: 2 * end, into: buffer) else { return nil }
        lastEnd = end
        return (UnsafeBufferPointer(start: buffer, count: 2 * count), count, rate)
    }

    public func reset() {
        cursor.reset()
        lastEnd = nil
    }
}
