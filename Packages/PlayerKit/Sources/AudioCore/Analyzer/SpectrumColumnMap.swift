import Foundation

/// Maps FFT bins onto log-spaced display columns. Allocates; build it off the audio thread.
public struct SpectrumColumnMap: Sendable {
    public let fftSize: Int
    public let sampleRate: Double
    /// One non-empty bin range per column; lower bounds are non-decreasing; bin 0 (DC) is skipped.
    public let ranges: [Range<Int>]

    public init(fftSize: Int, sampleRate: Double, columnCount: Int = 75,
                lowHz: Double = 40, highHz: Double = 16_000) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        let binWidth = sampleRate / Double(fftSize)
        let top = min(highHz, sampleRate / 2 - binWidth)
        let half = fftSize / 2
        var edges: [Int] = []
        edges.reserveCapacity(columnCount + 1)
        for c in 0...columnCount {
            let hz = lowHz * pow(top / lowHz, Double(c) / Double(columnCount))
            edges.append(min(max(1, Int((hz / binWidth).rounded())), half - 1))
        }
        ranges = (0..<columnCount).map { c in
            edges[c]..<min(max(edges[c] + 1, edges[c + 1]), half)
        }
    }

    public func bin(forFrequency hz: Double) -> Int {
        Int((hz / sampleRate * Double(fftSize)).rounded())
    }

    /// Frequency span covered by a column's bins (bin centers).
    public func frequencyRange(ofColumn c: Int) -> ClosedRange<Double> {
        let width = sampleRate / Double(fftSize)
        let r = ranges[c]
        return (Double(r.lowerBound) * width)...(Double(r.upperBound - 1) * width)
    }
}
