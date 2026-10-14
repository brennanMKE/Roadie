import CoreGraphics
import Testing
@testable import SkinKit

@Suite struct EQGraphTests {
    @Test func splineInterpolatesKnotsExactly() {
        let curve = CubicSpline.interpolate(xs: [0, 12, 24], ys: [3, 9, 3])
        #expect(curve.count == 25)
        #expect(abs(curve[0] - 3) < 1e-9 && abs(curve[12] - 9) < 1e-9 && abs(curve[24] - 3) < 1e-9)
        #expect(abs(curve[6] - curve[18]) < 1e-9)
        let line = CubicSpline.interpolate(xs: [0, 12, 24], ys: [0, 6, 12])
        for x in 0...24 { #expect(abs(line[x] - Double(x) / 2) < 1e-9) }
    }

    @Test func flatCurveIsRowNine() {
        let flat = EQGraph.curve(values: Array(repeating: 50, count: 10))
        #expect(flat.count == 109)
        #expect(flat.allSatisfy { $0 == 9 })
        #expect(EQGraph.knotY(forValue: 50) == 9)
        #expect(EQGraph.knotY(forValue: 100) == 0)
        #expect(EQGraph.knotY(forValue: 0) == 18)
        #expect(EQGraph.preampLineY(forValue: 50) == 9)
        #expect(EQGraph.preampLineY(forValue: 0) == 0)
        #expect(EQGraph.preampLineY(forValue: 100) == 18)
    }

    @Test func curveStaysInsideTheGraph() {
        let values: [Double] = [100, 0, 100, 0, 100, 0, 100, 0, 100, 0]
        let curve = EQGraph.curve(values: values)
        #expect(curve.count == 109)
        #expect(curve.allSatisfy { (0...18).contains($0) })
        for i in 0..<10 { #expect(curve[12 * i] == EQGraph.knotY(forValue: values[i])) }
    }

    /// An EQMAIN sheet of `height` rows: graph background blue, preamp line red, line colour for row r = (r, 0, 0).
    private func skin(height: Int) -> Skin {
        let context = CGContext(
            data: nil, width: 275, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            context.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
        }
        fill(0, 0, 1, 0, 294, 113, 19)
        fill(1, 0, 0, 0, 314, 113, 1)
        for r in 0..<19 { fill(CGFloat(r) / 255, 0, 0, 115, 294 + r, 1, 1) }
        return Skin(sheets: ["EQMAIN": context.makeImage()!], visColors: [], warnings: [])
    }

    @Test func renderDrawsBackgroundPreampAndCurveColours() throws {
        let image = try #require(EQGraph.render(skin: skin(height: 315), values: Array(repeating: 50, count: 10), preamp: 50))
        #expect(image.width == 113 && image.height == 19)
        #expect(TestBitmaps.pixel(image, x: 1, y: 4) == RGBColor(red: 0, green: 0, blue: 255))
        #expect(TestBitmaps.pixel(image, x: 2, y: 9) == RGBColor(red: 9, green: 0, blue: 0))
        #expect(TestBitmaps.pixel(image, x: 60, y: 9) == RGBColor(red: 9, green: 0, blue: 0))
        #expect(TestBitmaps.pixel(image, x: 1, y: 9) == RGBColor(red: 255, green: 0, blue: 0))
        #expect(TestBitmaps.pixel(image, x: 112, y: 9) == RGBColor(red: 255, green: 0, blue: 0))
        // The preamp line moves with the preamp value (Webamp's formula: 100 is the bottom row).
        let high = try #require(EQGraph.render(skin: skin(height: 315), values: Array(repeating: 50, count: 10), preamp: 100))
        #expect(TestBitmaps.pixel(high, x: 1, y: 18) == RGBColor(red: 255, green: 0, blue: 0))
    }

    @Test func renderIsNilWithoutLineColours() {
        #expect(EQGraph.render(skin: skin(height: 294), values: Array(repeating: 50, count: 10), preamp: 50) == nil)
        #expect(EQGraph.render(skin: Skin(sheets: [:], visColors: [], warnings: []), values: [], preamp: 50) == nil)
    }
}
