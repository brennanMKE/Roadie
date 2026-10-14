import CoreGraphics
import Foundation

/// Decodes the ICO/CUR container: a directory of entries, each a PNG or a DIB (XOR bitmap plus 1-bpp AND mask).
/// ImageIO is only used for PNG entries; the DIB path is hand-written so hotspots and masks behave the same everywhere.
enum CursorBitmap {
    static let maxDimension = 256
    static let maxEntries = 64

    private struct Entry {
        var width: Int        // 0 in the directory means 256
        var height: Int
        var hotSpot: CGPoint
        var start: Int
        var end: Int
        var bitCount: Int
    }

    /// The frame of the entry closest to 32x32 that decodes; nil for anything malformed.
    static func decode(_ bytes: [UInt8]) -> SkinCursor.Frame? {
        var reader = ByteReader(bytes)
        guard reader.u16() == 0, let type = reader.u16(), type == 1 || type == 2,
              let count = reader.u16(), count >= 1, Int(count) <= maxEntries
        else { return nil }
        var entries: [Entry] = []
        for _ in 0..<Int(count) {
            guard let w = reader.u8(), let h = reader.u8(), reader.u8() != nil, reader.u8() != nil,
                  let hx = reader.u16(), let hy = reader.u16(), let size = reader.u32(), let offset = reader.u32()
            else { return nil }
            let start = Int(offset)
            guard start >= 0, start < bytes.count else { continue }
            // A size that overruns is clamped to what is there; 0 means "to the end".
            let end = size == 0 ? bytes.count : min(start + Int(size), bytes.count)
            let hot = type == 2 ? CGPoint(x: Int(hx), y: Int(hy)) : .zero
            entries.append(
                Entry(
                    width: w == 0 ? 256 : Int(w), height: h == 0 ? 256 : Int(h), hotSpot: hot, start: start, end: end,
                    bitCount: dibBitCount(bytes, start: start, end: end)))
        }
        // Winamp loads at the 32x32 system size; ties go to the higher bit depth.
        let ordered = entries.enumerated().sorted { a, b in
            let da = abs(a.element.width - 32) + abs(a.element.height - 32)
            let db = abs(b.element.width - 32) + abs(b.element.height - 32)
            if da != db { return da < db }
            if a.element.bitCount != b.element.bitCount { return a.element.bitCount > b.element.bitCount }
            return a.offset < b.offset
        }
        for (_, entry) in ordered {
            if let frame = decodeEntry(bytes, entry) { return frame }
        }
        return nil
    }

    private static func dibBitCount(_ bytes: [UInt8], start: Int, end: Int) -> Int {
        guard end - start >= 16 else { return 0 }
        return Int(bytes[start + 14]) | Int(bytes[start + 15]) << 8
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

    private static func decodeEntry(_ bytes: [UInt8], _ entry: Entry) -> SkinCursor.Frame? {
        guard entry.end > entry.start else { return nil }
        if entry.end - entry.start >= 4, Array(bytes[entry.start..<entry.start + 4]) == pngSignature {
            guard let image = BitmapLoader.image(from: Data(bytes[entry.start..<entry.end])),
                  image.width >= 1, image.height >= 1, image.width <= maxDimension, image.height <= maxDimension
            else { return nil }
            return SkinCursor.Frame(image: image, hotSpot: clamp(entry.hotSpot, width: image.width, height: image.height))
        }
        return decodeDIB(bytes, entry)
    }

    private static func clamp(_ point: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), CGFloat(width - 1)), y: min(max(point.y, 0), CGFloat(height - 1)))
    }

    private static func decodeDIB(_ bytes: [UInt8], _ entry: Entry) -> SkinCursor.Frame? {
        var r = ByteReader(Array(bytes[entry.start..<entry.end]))
        guard let biSize = r.u32(), biSize >= 40, Int(biSize) <= r.bytes.count,
              let biWidth = r.i32(), let biHeight = r.i32(), r.u16() != nil, let bpp16 = r.u16(),
              let compression = r.u32(), r.u32() != nil, r.u32() != nil, r.u32() != nil, let clrUsed = r.u32()
        else { return nil }
        let bitCount = Int(bpp16)
        guard [1, 2, 4, 8, 16, 24, 32].contains(bitCount), compression == 0 || compression == 3 else { return nil }
        guard biWidth >= 1, Int(biWidth) <= maxDimension, biHeight >= 1, Int(biHeight) <= 2 * maxDimension else { return nil }
        let width = Int(biWidth)
        // The header height is twice the image height when an AND mask follows; the directory height says which.
        let height: Int
        let hasMask: Bool
        if Int(biHeight) == 2 * entry.height {
            height = entry.height
            hasMask = true
        } else if Int(biHeight) == entry.height {
            height = entry.height
            hasMask = false
        } else {
            return nil
        }
        guard height >= 1, height <= maxDimension else { return nil }

        var dataStart = Int(biSize)
        if compression == 3 {
            // BI_BITFIELDS: only the default 32-bpp BGRA layout.
            guard bitCount == 32, r.seek(to: 40), r.u32() == 0x00FF_0000, r.u32() == 0x0000_FF00, r.u32() == 0x0000_00FF
            else { return nil }
            dataStart = max(dataStart, 52)
        }
        var palette: [UInt8] = []
        if bitCount <= 8 {
            let full = 1 << bitCount
            let used = clrUsed == 0 || Int(clrUsed) > full ? full : Int(clrUsed)
            guard r.seek(to: dataStart) else { return nil }
            // A palette cut short by the end of the data leaves its missing indices black.
            palette = r.bytes(min(used * 4, r.remaining)) ?? []
            dataStart += used * 4
        }
        let xorStride = ((width * bitCount + 31) / 32) * 4
        let xorStart = dataStart
        guard xorStart + xorStride * height <= r.bytes.count else { return nil }
        let andStride = ((width + 31) / 32) * 4
        let andStart = xorStart + xorStride * height
        let data = r.bytes

        // First pass for 32-bpp: does any pixel carry alpha? Old files leave it all zero and rely on the mask.
        var hasAlpha = false
        if bitCount == 32 {
            outer: for row in 0..<height {
                for x in 0..<width where data[xorStart + row * xorStride + x * 4 + 3] != 0 {
                    hasAlpha = true
                    break outer
                }
            }
        }

        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let storedRow = height - 1 - y   // bottom-up
            let xorRow = xorStart + storedRow * xorStride
            let andRow = andStart + storedRow * andStride
            for x in 0..<width {
                var red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0, alpha: UInt8 = 255
                switch bitCount {
                case 1, 2, 4, 8:
                    let bitIndex = x * bitCount
                    let byte = data[xorRow + bitIndex / 8]
                    let shift = 8 - bitCount - (bitIndex % 8)
                    let index = Int(byte >> UInt8(shift)) & ((1 << bitCount) - 1)
                    if index * 4 + 2 < palette.count {
                        blue = palette[index * 4]; green = palette[index * 4 + 1]; red = palette[index * 4 + 2]
                    }
                case 16:
                    let value = Int(data[xorRow + x * 2]) | Int(data[xorRow + x * 2 + 1]) << 8
                    red = UInt8((value >> 10 & 31) * 255 / 31)
                    green = UInt8((value >> 5 & 31) * 255 / 31)
                    blue = UInt8((value & 31) * 255 / 31)
                case 24:
                    blue = data[xorRow + x * 3]; green = data[xorRow + x * 3 + 1]; red = data[xorRow + x * 3 + 2]
                default:
                    blue = data[xorRow + x * 4]; green = data[xorRow + x * 4 + 1]; red = data[xorRow + x * 4 + 2]
                    if hasAlpha { alpha = data[xorRow + x * 4 + 3] }
                }
                let masked = hasMask && ByteReader.bit(x, in: data, rowStart: andRow)
                if masked {
                    // AND 1: the screen shows through. XOR black is transparent; a coloured XOR would invert the
                    // screen, which NSCursor cannot do, so it is drawn opaque in its own colour (documented deviation).
                    if hasAlpha || (red == 0 && green == 0 && blue == 0) { alpha = 0; red = 0; green = 0; blue = 0 }
                }
                let o = (y * width + x) * 4
                if alpha == 255 {
                    out[o] = red; out[o + 1] = green; out[o + 2] = blue; out[o + 3] = 255
                } else {
                    out[o] = UInt8((Int(red) * Int(alpha) + 127) / 255)
                    out[o + 1] = UInt8((Int(green) * Int(alpha) + 127) / 255)
                    out[o + 2] = UInt8((Int(blue) * Int(alpha) + 127) / 255)
                    out[o + 3] = alpha
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return SkinCursor.Frame(image: image, hotSpot: clamp(entry.hotSpot, width: width, height: height))
    }
}
