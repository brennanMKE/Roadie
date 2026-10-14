/// A read position in the analyzer ring that advances with wall-clock time and stays one tap delivery
/// behind the write counter, so every display tick analyzes a fresh, contiguous window even though audio
/// arrives in 4800-frame bursts about 10 times a second. Pure: no audio, no clock.
public struct VisReadCursor: Sendable {
    public let window: Int
    public let readable: Int
    /// Extra lag so clock drift does not run the cursor dry.
    public var slackSeconds: Double = 0.02
    /// Absolute index the last window ended at.
    public private(set) var position: Int?
    /// Largest `writeCount` jump seen; starts at `window`.
    public private(set) var largestDelivery: Int
    private var lastWriteCount: Int?
    private var stalledSeconds: Double = 0
    /// Sub-sample remainder of `dt * sampleRate`, so rounding never biases the cursor against the audio.
    private var carry: Double = 0

    /// `window` is the FFT size; `readable` is `ring.capacity - ring.maxChunk`.
    public init(window: Int, readable: Int) {
        self.window = window
        self.readable = readable
        largestDelivery = window
    }

    /// End index of the next window, or nil while fewer than `window` samples exist.
    public mutating func next(writeCount: Int, elapsed dt: Double, sampleRate: Double) -> Int? {
        if let last = lastWriteCount {
            if writeCount > last {
                largestDelivery = max(largestDelivery, writeCount - last)
                stalledSeconds = 0
            } else {
                stalledSeconds += dt
            }
        }
        lastWriteCount = writeCount
        guard writeCount >= window else { return nil }

        let slack = Int(slackSeconds * sampleRate)
        let lag = min(largestDelivery + slack, readable - window)
        let steady = writeCount - lag
        let advance = dt * sampleRate + carry
        let step = Int(advance.rounded())
        carry = advance - Double(step)
        var p = (position ?? steady) + step
        // Ran into the slack margin or past the audio (clock drift, or the lag was learned too small): re-lag.
        if p > writeCount - slack { p = steady }
        if p < writeCount - readable + window { p = steady }          // main thread stalled, ring wrapped
        // Drifted later than one delivery past the steady lag (audio clock faster than the display): catch up.
        if writeCount - p > lag + largestDelivery + slack { p = steady }
        if stalledSeconds * sampleRate > Double(2 * largestDelivery) { p = writeCount }  // audio stopped
        p = max(p, window)
        position = p
        return p
    }

    public mutating func reset() {
        position = nil
        lastWriteCount = nil
        stalledSeconds = 0
        carry = 0
    }
}
