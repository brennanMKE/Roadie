/// Winamp-style bar falloff and peak hold; pure, applied by the UI at display rate.
public struct VisSmoother: Sendable {
    public var barFallPerSecond: Float = 3.0
    public var peakHoldSeconds: Double = 0.5
    public var peakFallPerSecond: Float = 1.5
    public private(set) var bars: [Float]
    public private(set) var peaks: [Float]
    private var peakAge: [Double]

    public init(columnCount: Int = VisFrame.columnCount) {
        bars = Array(repeating: 0, count: columnCount)
        peaks = Array(repeating: 0, count: columnCount)
        peakAge = Array(repeating: 0, count: columnCount)
    }

    public mutating func step(_ frame: VisFrame, dt: Double) {
        let fall = barFallPerSecond * Float(dt)
        let peakFall = peakFallPerSecond * Float(dt)
        for i in 0..<min(bars.count, frame.spectrum.count) {
            let v = frame.spectrum[i]
            bars[i] = max(v, bars[i] - fall)
            if bars[i] >= peaks[i] {
                peaks[i] = bars[i]
                peakAge[i] = 0
            } else {
                peakAge[i] += dt
                if peakAge[i] > peakHoldSeconds { peaks[i] = max(bars[i], peaks[i] - peakFall) }
            }
        }
    }
}
