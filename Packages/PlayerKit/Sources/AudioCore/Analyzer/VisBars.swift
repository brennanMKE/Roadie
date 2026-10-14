import Foundation

/// Bar falloff and peak hold for the main-window spectrum, ported from Webamp's `BarPaintHandler.paintAnalyzer`
/// (packages/webamp/js/components/VisPainter.ts, MIT; see NOTICE) with the main window's fixed settings:
/// wide bandwidth, "moderate" bar falloff, "slow" peak falloff.
///
/// Webamp's arithmetic truncates through `Int16Array`s, so this advances in fixed 60 Hz steps instead of
/// scaling by `dt`; the caller runs whole steps (see `VisualizerModel`). Pure and deterministic.
public struct VisBars: Sendable {
    public static let columnCount = 75
    /// Pixels (in 1/16) the bars fall per step: 12 is the default of a fresh Winamp install.
    public var falloff: Float = 12
    /// Per-step growth of the peak drop.
    public var peakFalloff: Float = 1.1
    public var maxHeight = 15
    /// 2 at 1x, 0 at 2x (Winamp draws the main-window vis 2 px lower at 1x).
    public var pushDown = 0
    /// 75 values: `round(falloff) - pushDown`, never negative. The renderer skips every fourth column.
    public private(set) var heights: [Int]
    /// 75 values: `barPeak + 1 - pushDown`; 0 or less means hidden.
    public private(set) var peaks: [Int]

    private var fallingBars: [Float]
    private var peakPositions: [Int]   // 1/256 px
    private var peakDrops: [Float]

    public init() {
        let n = Self.columnCount
        heights = Array(repeating: 0, count: n)
        peaks = Array(repeating: 0, count: n)
        fallingBars = Array(repeating: 0, count: n)
        peakPositions = Array(repeating: 0, count: n)
        peakDrops = Array(repeating: 0, count: n)
    }

    /// One 60 Hz step. `spectrum` is `VisFrame.spectrum` (0...1, 75 values); silence makes everything fall.
    public mutating func step(_ spectrum: [Float]) {
        let n = Self.columnCount
        func sample(_ i: Int) -> Float {
            i < n && i < spectrum.count ? min(spectrum[i] * 16, 15) : 0
        }
        for x in 0..<n {
            let chunk = x & ~3
            let sum = sample(chunk) + sample(chunk + 1) + sample(chunk + 2) + sample(chunk + 3)
            let data = min(Int(sum / 4), maxHeight)

            fallingBars[x] -= falloff / 16
            if fallingBars[x] <= Float(data) { fallingBars[x] = Float(data) }

            if peakPositions[x] <= Int((fallingBars[x] * 256).rounded()) {
                peakPositions[x] = Int(fallingBars[x] * 256)
                peakDrops[x] = 3
            }
            peakPositions[x] = min(peakPositions[x], maxHeight * 256)
            var barPeak = peakPositions[x] / 256
            peakPositions[x] -= Int(peakDrops[x].rounded())
            peakDrops[x] *= peakFalloff
            peakPositions[x] = max(peakPositions[x], 0)
            if barPeak < 1 { barPeak = -3 }

            heights[x] = max(0, Int(fallingBars[x].rounded()) - pushDown)
            peaks[x] = barPeak + 1 - pushDown
        }
    }
}
