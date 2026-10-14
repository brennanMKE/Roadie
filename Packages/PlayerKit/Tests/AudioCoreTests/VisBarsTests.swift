import Testing
@testable import AudioCore

@Suite struct VisBarsTests {
    private let loud = [Float](repeating: 1, count: 75)
    private let silent = [Float](repeating: 0, count: 75)

    @Test func wideBandwidthAveragesChunksOfFour() {
        var bars = VisBars()
        var spectrum = silent
        spectrum[0] = 1
        bars.step(spectrum)
        #expect(Array(bars.heights[0...3]) == [3, 3, 3, 3])   // Int((15 + 0 + 0 + 0) / 4) truncates 3.75
        #expect(bars.heights[4] == 0)
    }

    @Test func inputIsClampedToMaxHeight() {
        var bars = VisBars()
        bars.step(loud)
        // The last chunk (72...75) averages in Webamp's always-empty 76th entry: Int(45 / 4) = 11.
        #expect(bars.heights[0..<72].allSatisfy { $0 == 15 })
        #expect(bars.heights[72...].allSatisfy { $0 == 11 })
        var over = VisBars()
        over.step([Float](repeating: 2, count: 75))
        #expect(over.heights[0..<72].allSatisfy { $0 == 15 })
        #expect(over.heights.allSatisfy { $0 <= 15 })
    }

    @Test func barsFallThreeQuartersOfAPixelPerStep() {
        var bars = VisBars()
        bars.step(loud)
        var seen: [Int: Int] = [:]
        var previous = bars.heights[0]
        for n in 1...20 {
            bars.step(silent)
            #expect(bars.heights[0] <= previous)
            previous = bars.heights[0]
            seen[n] = previous
        }
        #expect(seen[1] == 14)   // 14.25
        #expect(seen[2] == 14)   // 13.5 rounds up
        #expect(seen[4] == 12)
        #expect(seen[20] == 0)
    }

    @Test func peakHoldsThenAcceleratesAndHides() {
        var bars = VisBars()
        bars.step(loud)
        #expect(bars.peaks[0] == 16)
        var previous = bars.peaks[0]
        for n in 1...60 {
            bars.step(silent)
            if n <= 20 { #expect(bars.peaks[0] >= 15) }   // holds near the top while the bar falls away
            #expect(bars.peaks[0] <= previous)
            previous = bars.peaks[0]
        }
        #expect(bars.peaks[0] <= 0)
        #expect(bars.heights[0] == 0)
    }

    @Test func pushDownShortensBarsAndPeaks() {
        var bars = VisBars()
        bars.pushDown = 2
        bars.step(loud)
        #expect(bars.heights[0] == 13)
        #expect(bars.peaks[0] == 14)
        for _ in 0..<80 { bars.step(silent) }
        #expect(bars.peaks[0] <= 0)
    }

    @Test func stepIsDeterministic() {
        var a = VisBars()
        var b = VisBars()
        for i in 0..<120 {
            let spectrum = (0..<75).map { Float((($0 * 7 + i * 13) % 17)) / 16 }
            a.step(spectrum)
            b.step(spectrum)
        }
        #expect(a.heights == b.heights)
        #expect(a.peaks == b.peaks)
    }

    @Test func smallVisKeepsLowPeaksOnTheBottomRow() {
        var small = VisBars()
        small.smallVis = true
        small.maxHeight = 5
        small.step(loud)
        #expect(small.heights[0] == 5)
        #expect(small.peaks[0] == 6)
        for _ in 0..<200 { small.step(silent) }
        #expect(small.peaks[0] == 1)
        #expect(small.heights[0] == 0)

        var main = VisBars()
        main.step(loud)
        for _ in 0..<200 { main.step(silent) }
        #expect(main.peaks[0] <= 0)
        #expect(main.heights[0] == 0)

        // A 37-value spectrum (the 1x shade strip) leaves the columns beyond it at 0.
        var narrow = VisBars()
        narrow.smallVis = true
        narrow.maxHeight = 5
        narrow.step([Float](repeating: 1, count: 37))
        #expect(narrow.heights[0] == 5)
        #expect(narrow.heights[40...].allSatisfy { $0 == 0 })
    }
}
