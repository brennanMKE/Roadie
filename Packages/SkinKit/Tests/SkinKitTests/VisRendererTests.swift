import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

struct VisRendererTests {
    private let c = VisColorParser.defaults

    private func renderer() -> VisRenderer { VisRenderer(colors: c) }

    private func heights(_ values: [Int: Int]) -> [Int] {
        var h = [Int](repeating: 0, count: 75)
        for (x, v) in values { h[x] = v }
        return h
    }

    private let noPeaks = [Int](repeating: 0, count: 75)

    @Test func shortPaletteIsPadded() {
        var r = VisRenderer(colors: Array(c.prefix(2)))
        r.clear()
        #expect(r.color(x: 0, y: 0) == c[0])
        #expect(r.color(x: 0, y: 1) == c[1])
        r.drawBars(heights: heights([0: 16]), peaks: noPeaks, pushDown: 0)   // does not trap on missing entries
        #expect(r.color(x: 0, y: 15) == c[1])
    }

    @Test func backgroundIsColorZeroWithGridDotsOfColorOne() {
        var r = renderer()
        r.clear()
        #expect(r.color(x: 0, y: 0) == c[0])
        #expect(r.color(x: 0, y: 1) == c[1])
        #expect(r.color(x: 1, y: 1) == c[0])
        #expect(r.color(x: 2, y: 1) == c[1])
        #expect(r.color(x: 0, y: 2) == c[0])
        #expect(r.color(x: 74, y: 15) == c[1])
        #expect(r.color(x: 75, y: 15) == c[0])
    }

    @Test func barsUseGradientFromBottomAndSkipEveryFourthColumn() {
        var r = renderer()
        r.clear()
        r.drawBars(heights: heights([0: 5, 3: 5, 4: 16]), peaks: noPeaks, pushDown: 0)
        for (n, y) in (11...15).enumerated() { #expect(r.color(x: 0, y: y) == c[13 + n]) }
        #expect(r.color(x: 0, y: 10) == c[0])
        #expect(r.color(x: 3, y: 15) == c[0])   // skipped column stays background (no grid dot at odd x)
        #expect(r.color(x: 3, y: 14) == c[0])
        for y in 0..<16 { #expect(r.color(x: 4, y: y) == c[2 + y]) }
    }

    @Test func pushDownShiftsGradient() {
        var r = renderer()
        r.clear()
        r.drawBars(heights: heights([0: 5]), peaks: noPeaks, pushDown: 2)
        for (n, y) in (11...15).enumerated() { #expect(r.color(x: 0, y: y) == c[11 + n]) }
    }

    @Test func peakIsColor23OneRowAboveItsHeight() {
        func hasPeak(_ r: VisRenderer) -> Bool { (0..<16).contains { r.color(x: 0, y: $0) == c[23] } }
        var r = renderer()
        r.clear()
        var peaks = noPeaks
        peaks[0] = 8
        r.drawBars(heights: noPeaks, peaks: peaks, pushDown: 0)
        #expect(r.color(x: 0, y: 8) == c[23])

        r.clear()
        peaks[0] = -3
        r.drawBars(heights: noPeaks, peaks: peaks, pushDown: 0)
        #expect(!hasPeak(r))

        r.clear()
        peaks[0] = 16
        r.drawBars(heights: noPeaks, peaks: peaks, pushDown: 0)
        #expect(r.color(x: 0, y: 0) == c[23])
    }

    @Test func oscilloscopeSilenceDrawsCenterRow() {
        var r = renderer()
        r.clear()
        r.drawOscilloscope([Float](repeating: 0, count: 75), pushDown: 0)
        for x in 0..<75 {
            #expect(r.color(x: x, y: 7) == c[18])
            #expect(r.color(x: x, y: 6) == c[0])      // even rows hold no grid dots
            #expect(r.color(x: x, y: 8) == c[0])
            #expect(r.color(x: x, y: 9) == (x % 2 == 0 ? c[1] : c[0]))
        }
        #expect(r.color(x: 75, y: 7) == c[0])         // untouched column

        r.clear()
        r.drawOscilloscope([Float](repeating: 0, count: 75), pushDown: 2)
        #expect(r.color(x: 10, y: 9) == c[18])
        #expect(r.color(x: 10, y: 7) != c[18])
    }

    @Test func oscilloscopeConnectsSamplesVertically() {
        var r = renderer()
        r.clear()
        var samples = [Float](repeating: 0, count: 75)
        samples[1] = 0.5; samples[2] = -0.5; samples[3] = 0.5
        r.drawOscilloscope(samples, pushDown: 0)
        for y in 8...15 { #expect(r.color(x: 1, y: y) == c[22]) }
        for y in 0...15 { #expect(r.color(x: 2, y: y) == c[21]) }
        for y in 1...15 { #expect(r.color(x: 3, y: y) == c[22]) }
        r.clear()
        samples[1] = 2; samples[2] = -2
        r.drawOscilloscope(samples, pushDown: 0)
        #expect(r.color(x: 1, y: 15) == c[22])   // clips to row 15
        #expect(r.color(x: 2, y: 0) == c[21])    // clips to row 0
    }

    @Test func makeImageIs76x16Opaque() throws {
        var r = renderer()
        r.clear()
        let image = try #require(r.makeImage())
        #expect(image.width == 76 && image.height == 16)
        #expect(image.bitmapInfo.rawValue == VisRenderer.bitmapInfo.rawValue)
        #expect(image.alphaInfo == .premultipliedFirst)
    }

    @Test func renderFrameStaysUnderOneMillisecond() {
        var r = renderer()
        let heights = (0..<75).map { $0 % 17 }
        let peaks = (0..<75).map { ($0 % 17) + 1 }
        let scope = (0..<75).map { Float(sin(Double($0) / 5)) }
        let iterations = 1_000
        let clock = ContinuousClock()
        var sink = 0
        let elapsed = clock.measure {
            for i in 0..<iterations {
                r.clear()
                if i % 2 == 0 { r.drawBars(heights: heights, peaks: peaks, pushDown: 0) } else { r.drawOscilloscope(scope, pushDown: 0) }
                sink &+= r.makeImage()?.width ?? 0
            }
        }
        let meanMicroseconds = Double(elapsed.components.attoseconds) / 1e12 / Double(iterations)
            + Double(elapsed.components.seconds) * 1e6 / Double(iterations)
        print("VisRenderer mean frame time: \(meanMicroseconds) us over \(iterations) frames")
        #expect(sink == 76 * iterations)
        #expect(meanMicroseconds < 1_000)
    }

    // MARK: Shade layouts

    @Test func shadeLayoutsHaveWebampSizes() {
        let one = VisLayout.shade(pixelDensity: 1)
        #expect(one.imageSize.width == 76 && one.imageSize.height == 5)
        #expect(one.columnCount == 37 && one.maxHeight == 5 && one.backgroundWidth == 38 && one.pointScale == 1)
        let two = VisLayout.shade(pixelDensity: 2)
        #expect(two.imageSize.width == 152 && two.imageSize.height == 10)
        #expect(two.columnCount == 75 && two.maxHeight == 10 && two.backgroundWidth == 152 && two.pointScale == 2)
        let main = VisLayout.main
        #expect(main.imageSize.width == 76 && main.imageSize.height == 16)
        #expect(main.columnCount == 75 && main.maxHeight == 15 && main.backgroundWidth == 76 && main.pointScale == 1)
    }

    @Test func shadeBackgroundHasNoGridAndStopsAtThirtyEight() {
        var r = VisRenderer(colors: c, layout: .shade(pixelDensity: 1))
        r.clear()
        #expect(r.color(x: 0, y: 1) == c[0] && r.color(x: 2, y: 1) == c[0])
        #expect(r.color(x: 37, y: 4) == c[0])
        #expect(r.alpha(x: 37, y: 4) == 255)
        #expect(r.alpha(x: 38, y: 0) == 0 && r.alpha(x: 75, y: 4) == 0)
        var d = VisRenderer(colors: c, layout: .shade(pixelDensity: 2))
        d.clear()
        #expect(d.color(x: 0, y: 1) == c[0])
        #expect(d.alpha(x: 151, y: 9) == 255)
    }

    @Test func shadeBarsUseTheSmallRamps() {
        var r = VisRenderer(colors: c, layout: .shade(pixelDensity: 1))
        r.clear()
        var h = [Int](repeating: 0, count: 75)
        h[0] = 5; h[3] = 5; h[38] = 5
        r.drawBars(heights: h, peaks: noPeaks, pushDown: 0)
        for (y, index) in [4, 8, 11, 14, 17].enumerated() { #expect(r.color(x: 0, y: y) == c[index]) }
        #expect(r.color(x: 3, y: 4) == c[0])
        #expect(r.alpha(x: 38, y: 4) == 0)

        var d = VisRenderer(colors: c, layout: .shade(pixelDensity: 2))
        d.clear()
        h[0] = 12
        d.drawBars(heights: h, peaks: noPeaks, pushDown: 0)
        for (y, index) in [4, 5, 7, 8, 10, 11, 13, 14, 16, 17].enumerated() { #expect(d.color(x: 0, y: y) == c[index]) }
    }

    @Test func shadePeaksDrawOnTheBottomRow() {
        var r = VisRenderer(colors: c, layout: .shade(pixelDensity: 1))
        r.clear()
        var peaks = noPeaks
        peaks[0] = 1
        r.drawBars(heights: noPeaks, peaks: peaks, pushDown: 0)
        #expect(r.color(x: 0, y: 4) == c[23])
        r.clear()
        peaks[0] = 6
        r.drawBars(heights: noPeaks, peaks: peaks, pushDown: 0)
        #expect((0..<5).allSatisfy { r.color(x: 0, y: $0) == c[0] })
    }

    @Test func shadeOscilloscopeMapsToFiveOrTenRows() {
        var r = VisRenderer(colors: c, layout: .shade(pixelDensity: 1))
        r.clear()
        r.drawOscilloscope([Float](repeating: 0, count: 37), pushDown: 0)
        for x in [0, 10, 36] { #expect(r.color(x: x, y: 2) == c[18]) }
        #expect(r.alpha(x: 38, y: 2) == 0)

        var d = VisRenderer(colors: c, layout: .shade(pixelDensity: 2))
        d.clear()
        d.drawOscilloscope([Float](repeating: 0, count: 75), pushDown: 0)
        for x in [0, 30, 74] { #expect(d.color(x: x, y: 4) == c[18]) }

        // 1.0 then -1.0 spans rows 4...0; -1.0 then 1.0 joins the same five rows (no main-window `top += 1` nudge).
        for samples: [Float] in [[1, -1], [-1, 1]] {
            var s = VisRenderer(colors: c, layout: .shade(pixelDensity: 1))
            s.clear()
            s.drawOscilloscope(samples, pushDown: 0)
            let painted = (0..<5).filter { s.color(x: 1, y: $0) == c[18] }
            #expect(painted == [0, 1, 2, 3, 4])
        }
    }
}
