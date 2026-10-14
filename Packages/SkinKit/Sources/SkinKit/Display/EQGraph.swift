import CoreGraphics
import Foundation

/// Port of Webamp's EqualizerWindow/EqGraph.tsx `drawEqLine`: the 113x19 graph for ten band values and a preamp
/// value, both on Webamp's 0...100 slider scale. Pure; the view only draws the image it returns.
public enum EQGraph {
    public static let size = CGSize(width: 113, height: 19)
    /// "Each band is 12 pixels wide".
    public static let bandSpacingX = 12
    public static let paddingLeft = 2
    private static let maxRow = 18

    /// y of a band knot: `percentToRange((100 - value) / 100, 0, 18)`, rounded.
    public static func knotY(forValue value: Double) -> Int {
        Int(((100 - clampedValue(value)) / 100 * Double(maxRow)).rounded())
    }

    /// Preamp line row: `percentToRange(preamp / 100, 0, 18)`. Webamp's formula verbatim, so +12 dB (value 100) puts
    /// the line on the bottom row, which reads inverted against the band curve (top = +12 dB).
    public static func preampLineY(forValue value: Double) -> Int {
        Int((clampedValue(value) / 100 * Double(maxRow)).rounded())
    }

    /// The curve rows for x 0...108 after the spline, each clamped to 0...18 (`Math.round` rounds halves up).
    public static func curve(values: [Double]) -> [Int] {
        let knots = (0..<EQLayout.bandCount).map { i in values.indices.contains(i) ? values[i] : EQLayout.midValue }
        let xs = (0..<knots.count).map { Double($0 * bandSpacingX) }
        let ys = knots.map { (100 - clampedValue($0)) / 100 * Double(maxRow) }
        return CubicSpline.interpolate(xs: xs, ys: ys).map { min(max(Int(($0 + 0.5).rounded(.down)), 0), maxRow) }
    }

    /// Composites the background, the preamp line and the curve from the skin's `EQ_GRAPH_*` and `EQ_PREAMP_LINE`
    /// sprites. nil when the skin has no `EQ_GRAPH_LINE_COLORS` (a short `eqmain.bmp`): Webamp draws nothing then.
    public static func render(skin: Skin, values: [Double], preamp: Double) -> CGImage? {
        guard let colorsImage = skin.image(for: "EQ_GRAPH_LINE_COLORS"), colorsImage.height == Int(size.height),
            let colors = lineColors(colorsImage),
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        let height = Int(size.height)
        if let background = skin.image(for: "EQ_GRAPH_BACKGROUND") {
            context.draw(background, in: CGRect(x: 0, y: 0, width: background.width, height: background.height)
                .offsetBy(dx: 0, dy: CGFloat(height - background.height)))
        }
        if let line = skin.image(for: "EQ_PREAMP_LINE") {
            let y = preampLineY(forValue: preamp)
            context.draw(line, in: CGRect(x: 0, y: height - y - line.height, width: line.width, height: line.height))
        }
        let rows = curve(values: values)
        var lastY = knotY(forValue: values.first ?? EQLayout.midValue)
        for (x, y) in rows.enumerated() {
            let top = min(y, lastY)
            for row in top..<(top + 1 + abs(lastY - y)) where row >= 0 && row < height {
                let c = colors[row]
                context.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
                context.fill(CGRect(x: paddingLeft + x, y: height - 1 - row, width: 1, height: 1))
            }
            lastY = y
        }
        return context.makeImage()
    }

    private static func clampedValue(_ value: Double) -> Double { min(max(value, 0), 100) }

    /// Pixel (0, r) of the 1x19 colour sprite for each row r (Webamp's repeat-x pattern is anchored at the canvas origin).
    private static func lineColors(_ image: CGImage) -> [(CGFloat, CGFloat, CGFloat)]? {
        var bytes = [UInt8](repeating: 0, count: image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: image.height, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setShouldAntialias(false)
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: image.height))
            return true
        }
        guard drawn else { return nil }
        return (0..<image.height).map { r in
            (CGFloat(bytes[r * 4]) / 255, CGFloat(bytes[r * 4 + 1]) / 255, CGFloat(bytes[r * 4 + 2]) / 255)
        }
    }
}
