import CoreGraphics
import Foundation

/// Draws the main window's 76x16 visualizer from `viscolor.txt` colors, headless and allocation-free per frame
/// (apart from the final image). Bar and oscilloscope painting is ported from Webamp's `VisPainter.ts` and
/// `Vis.tsx` (MIT; see NOTICE).
///
/// Pixels are premultiplied BGRA (all opaque). `clear()` copies the precomputed background (color 0 with
/// color 1 grid dots), then `drawBars` or `drawOscilloscope` paints over it.
public struct VisRenderer {
    public static let width = 76
    public static let height = 16
    /// Bars and the scope use x = 0...74; column 75 only shows the background.
    public static let barColumns = 75

    public static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    /// Webamp's default `viscolor.txt` (24 entries), for before a skin loads.
    public static let defaultColors = VisColorParser.defaults

    private let packed: [UInt32]
    private let template: [UInt32]
    private var pixels: [UInt32]

    /// `colors` is `Skin.visColors` (always 24 entries). A shorter list is padded with its last entry.
    public init(colors: [RGBColor]) {
        var padded = Array(colors.prefix(24))
        while padded.count < 24 { padded.append(padded.last ?? RGBColor(red: 0, green: 0, blue: 0)) }
        let packed = padded.map(Self.pack)
        self.packed = packed
        var bg = [UInt32](repeating: packed[0], count: Self.width * Self.height)
        // Vis.tsx preRenderBg: grid dots at every even x, odd y.
        for x in stride(from: 0, to: Self.width, by: 2) {
            for y in stride(from: 1, to: Self.height, by: 2) { bg[y * Self.width + x] = packed[1] }
        }
        template = bg
        pixels = bg
    }

    private static func pack(_ c: RGBColor) -> UInt32 {
        0xFF00_0000 | UInt32(c.red) << 16 | UInt32(c.green) << 8 | UInt32(c.blue)
    }

    /// Resets the pixels to the background (one copy of 1216 pixels).
    public mutating func clear() {
        pixels = template
    }

    /// `heights[x]` is 0...16 rows from the bottom; `peaks[x]` is the peak's row count (0 or less hides it).
    /// Every column with `x & 3 == 3` is skipped (wide bandwidth leaves 1 px gaps between 3 px bars).
    public mutating func drawBars(heights: [Int], peaks: [Int], pushDown: Int) {
        let w = Self.width, h = Self.height
        let columns = min(Self.barColumns, heights.count)
        let packed = packed
        pixels.withUnsafeMutableBufferPointer { px in
            for x in 0..<columns where x & 3 != 3 {
                let height = min(heights[x], h)
                if height > 0 {
                    for y in (h - height)..<h {
                        let index = min(max(2 - pushDown + y, 0), 23)
                        px[y * w + x] = packed[index]
                    }
                }
                if x < peaks.count {
                    let row = h - peaks[x]
                    if row >= 0 && row < h { px[row * w + x] = packed[23] }
                }
            }
        }
    }

    /// The first 75 samples (-1...1), Webamp's "lines" style: each column joins the previous sample's row to this one's.
    public mutating func drawOscilloscope(_ samples: [Float], pushDown: Int) {
        let w = Self.width, h = Self.height
        let columns = min(Self.barColumns, samples.count)
        guard columns > 0 else { return }
        let packed = packed
        pixels.withUnsafeMutableBufferPointer { px in
            var lastY = 0
            for x in 0..<columns {
                let y = min(max(7 + Int((16 * samples[x]).rounded()), 0), h - 1)
                if x == 0 { lastY = y }
                var top = y
                var bottom = lastY
                lastY = y
                if bottom < top {
                    swap(&top, &bottom)
                    top += 1   // emulates Winamp's OSC
                }
                let color = packed[18 + Self.scopeColorIndex(y)]
                for row in top...bottom where row + pushDown < h {
                    px[(row + pushDown) * w + x] = color
                }
            }
        }
    }

    /// VisPainter.ts lines 628-641: brighter in the middle, darker at the extremes.
    private static func scopeColorIndex(_ y: Int) -> Int {
        switch y {
        case 14...: 4
        case 12...: 3
        case 10...: 2
        case 8...: 1
        case 6...: 0
        case 4...: 1
        case 2...: 2
        default: 3
        }
    }

    /// A 76x16 opaque image of the current pixels (copies about 5 KB).
    public func makeImage() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress, width: Self.width, height: Self.height, bitsPerComponent: 8,
                bytesPerRow: Self.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: Self.bitmapInfo.rawValue)
            else { return nil }
            return context.makeImage()
        }
    }

    /// The color at a pixel (tests).
    public func color(x: Int, y: Int) -> RGBColor {
        let p = pixels[y * Self.width + x]
        return RGBColor(red: UInt8((p >> 16) & 0xFF), green: UInt8((p >> 8) & 0xFF), blue: UInt8(p & 0xFF))
    }
}
