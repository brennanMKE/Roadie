import CoreGraphics
import Foundation

/// Which visualizer a `VisRenderer` paints: the main window's 76x16 one or the 76x5 one in the shade strip.
/// Webamp draws the shade one at device resolution when the window is doubled (`pixelDensity` 2: 152x10 pixels, 75
/// columns), else at 38 columns' width (37 columns, 5 rows) (Vis.tsx 66-94, VisPainter.ts).
public enum VisLayout: Sendable, Equatable {
    case main
    case shade(pixelDensity: Int)

    private var isDouble: Bool {
        if case .shade(let density) = self { return density >= 2 }
        return false
    }

    public var imageSize: (width: Int, height: Int) {
        switch self {
        case .main: (76, 16)
        case .shade: isDouble ? (152, 10) : (76, 5)
        }
    }

    /// Bar and scope columns, x = 0..<columnCount.
    public var columnCount: Int {
        switch self {
        case .main: 75
        case .shade: isDouble ? 75 : 37
        }
    }

    public var maxHeight: Int {
        switch self {
        case .main: 15
        case .shade: isDouble ? 10 : 5
        }
    }

    /// Width of the opaque background; the rest of a shade image stays transparent so the strip shows through.
    public var backgroundWidth: Int {
        switch self {
        case .main: 76
        case .shade: isDouble ? 152 : 38
        }
    }

    /// Image pixels per skin pixel (`Image(decorative:scale:)`).
    public var pointScale: Int { isDouble ? 2 : 1 }

    var isShade: Bool { if case .shade = self { return true } else { return false } }
}

/// Draws the main window's 76x16 visualizer (or the shade strip's, see `VisLayout`) from `viscolor.txt` colors, headless
/// and allocation-free per frame (apart from the final image). Bar and oscilloscope painting is ported from Webamp's
/// `VisPainter.ts` and `Vis.tsx` (MIT; see NOTICE).
///
/// Pixels are premultiplied BGRA. `clear()` copies the precomputed background (color 0 with color 1 grid dots in the
/// main layout, plain color 0 in shade), then `drawBars` or `drawOscilloscope` paints over it. Shade pixels past
/// `backgroundWidth` are transparent.
public struct VisRenderer {
    public static let width = 76
    public static let height = 16
    /// Bars and the scope use x = 0...74 in the main layout; column 75 only shows the background.
    public static let barColumns = 75

    public static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    /// Webamp's default `viscolor.txt` (24 entries), for before a skin loads.
    public static let defaultColors = VisColorParser.defaults

    public let layout: VisLayout
    public var width: Int { layout.imageSize.width }
    public var height: Int { layout.imageSize.height }

    private let packed: [UInt32]
    private let template: [UInt32]
    private var pixels: [UInt32]

    /// `colors` is `Skin.visColors` (always 24 entries). A shorter list is padded with its last entry.
    public init(colors: [RGBColor], layout: VisLayout = .main) {
        self.layout = layout
        var padded = Array(colors.prefix(24))
        while padded.count < 24 { padded.append(padded.last ?? RGBColor(red: 0, green: 0, blue: 0)) }
        let packed = padded.map(Self.pack)
        self.packed = packed
        let (w, h) = layout.imageSize
        var bg = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<layout.backgroundWidth { bg[y * w + x] = packed[0] }
        }
        if !layout.isShade {
            // Vis.tsx preRenderBg: grid dots at every even x, odd y (not in shade, Vis.tsx 42-49).
            for x in stride(from: 0, to: w, by: 2) {
                for y in stride(from: 1, to: h, by: 2) { bg[y * w + x] = packed[1] }
            }
        }
        template = bg
        pixels = bg
    }

    private static func pack(_ c: RGBColor) -> UInt32 {
        0xFF00_0000 | UInt32(c.red) << 16 | UInt32(c.green) << 8 | UInt32(c.blue)
    }

    /// Resets the pixels to the background (one copy of 1216 pixels in the main layout).
    public mutating func clear() {
        pixels = template
    }

    /// The color index of the bar sprite at image row `y` (0 = top).
    private func barColor(row y: Int, pushDown: Int) -> UInt32 {
        switch layout {
        case .main:
            return packed[min(max(2 - pushDown + y, 0), 23)]
        case .shade:
            // VisPainter.ts colorssmall / colorssmall2, top to bottom.
            if layout.pointScale == 2 { return packed[[4, 5, 7, 8, 10, 11, 13, 14, 16, 17][min(max(y, 0), 9)]] }
            return packed[[4, 8, 11, 14, 17][min(max(y, 0), 4)]]
        }
    }

    /// `heights[x]` is 0...`maxHeight` rows from the bottom; `peaks[x]` is the peak's row count (0 or less hides it).
    /// Every column with `x & 3 == 3` is skipped (wide bandwidth leaves 1 px gaps between 3 px bars).
    public mutating func drawBars(heights: [Int], peaks: [Int], pushDown: Int) {
        let w = width, h = height
        let columns = min(layout.columnCount, heights.count)
        let packed = packed
        let colors = (0..<h).map { barColor(row: $0, pushDown: pushDown) }
        pixels.withUnsafeMutableBufferPointer { px in
            for x in 0..<columns where x & 3 != 3 {
                let height = min(heights[x], h)
                if height > 0 {
                    for y in (h - height)..<h { px[y * w + x] = colors[y] }
                }
                if x < peaks.count {
                    let row = h - peaks[x]
                    if row >= 0 && row < h { px[row * w + x] = packed[23] }
                }
            }
        }
    }

    /// The first `columnCount` samples (-1...1), Webamp's "lines" style: each column joins the previous sample's row to
    /// this one's.
    public mutating func drawOscilloscope(_ samples: [Float], pushDown: Int) {
        let w = width, h = height
        let columns = min(layout.columnCount, samples.count)
        guard columns > 0 else { return }
        let packed = packed
        let layout = layout
        pixels.withUnsafeMutableBufferPointer { px in
            var lastY = 0
            for x in 0..<columns {
                let y16 = 7 + Int((16 * samples[x]).rounded())
                let y: Int
                switch layout {
                case .main: y = min(max(y16, 0), h - 1)
                case .shade:
                    // VisPainter.ts 676-699; JS Math.round rounds halves up.
                    func round(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }
                    y = layout.pointScale == 2
                        ? min(max(round(Double(y16 + 8) / 16 * 10) - 5, 0), 9)
                        : min(max(round(Double(y16 + 6) / 16 * 5) - 2, 0), 4)
                }
                if x == 0 { lastY = y }
                var top = y
                var bottom = lastY
                lastY = y
                if bottom < top {
                    swap(&top, &bottom)
                    if !layout.isShade { top += 1 }   // emulates Winamp's OSC (not in shade, VisPainter.ts 738-745)
                }
                let color = layout.isShade ? packed[18] : packed[18 + Self.scopeColorIndex(y)]
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

    /// An opaque (shade: partly transparent) image of the current pixels in the layout's size.
    public func makeImage() -> CGImage? {
        var copy = pixels
        let w = width, h = height
        return copy.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: Self.bitmapInfo.rawValue)
            else { return nil }
            return context.makeImage()
        }
    }

    /// The color at a pixel (tests).
    public func color(x: Int, y: Int) -> RGBColor {
        let p = pixels[y * width + x]
        return RGBColor(red: UInt8((p >> 16) & 0xFF), green: UInt8((p >> 8) & 0xFF), blue: UInt8(p & 0xFF))
    }

    /// The alpha at a pixel (tests): 0 outside a shade layout's background.
    public func alpha(x: Int, y: Int) -> UInt8 {
        UInt8(pixels[y * width + x] >> 24)
    }
}
