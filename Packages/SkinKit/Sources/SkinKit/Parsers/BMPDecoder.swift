import CoreGraphics
import Foundation

/// A small pure-Swift BMP decoder used when ImageIO rejects a file. Handles 1/4/8-bit paletted, 16 (5-5-5 and
/// BI_BITFIELDS), 24 and 32-bit, RLE8 and RLE4, bottom-up and top-down rows, and BITMAPINFO / OS/2 BITMAPCORE headers.
/// Every failure returns nil; sizes are bounded before any allocation.
enum BMPDecoder {
    static let maxDimension = 4096
    static let maxPixels = 8 << 20

    static func decode(_ data: Data) -> CGImage? {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, bytes[0] == 0x42, bytes[1] == 0x4D else { return nil }
        var reader = ByteReader(bytes)
        guard reader.seek(to: 10), let offBits = reader.u32(), let headerSize = reader.u32() else { return nil }

        let width: Int, rawHeight: Int, bitCount: Int, compression: UInt32
        var clrUsed = 0
        let paletteEntrySize: Int
        switch headerSize {
        case 12:
            guard bytes.count >= 14 + 12,
                  let w = reader.u16(), let h = reader.u16(), reader.u16() != nil, let bc = reader.u16()
            else { return nil }
            width = Int(w); rawHeight = Int(h); bitCount = Int(bc); compression = 0
            paletteEntrySize = 3
        case 40, 52, 56, 108, 124:
            guard bytes.count >= 14 + Int(headerSize),
                  let w = reader.i32(), let h = reader.i32(), reader.u16() != nil, let bc = reader.u16(),
                  let comp = reader.u32(), reader.u32() != nil, reader.i32() != nil, reader.i32() != nil,
                  let used = reader.u32(), reader.u32() != nil
            else { return nil }
            width = Int(w); rawHeight = Int(h); bitCount = Int(bc); compression = comp
            clrUsed = Int(used)
            paletteEntrySize = 4
        default:
            return nil
        }

        let topDown = rawHeight < 0
        let height = abs(rawHeight)
        guard (1...maxDimension).contains(width), (1...maxDimension).contains(height),
              width * height <= maxPixels
        else { return nil }

        switch (compression, bitCount) {
        case (0, 1), (0, 4), (0, 8), (0, 16), (0, 24), (0, 32), (1, 8), (2, 4), (3, 16), (3, 32): break
        default: return nil
        }
        let isRLE = compression == 1 || compression == 2
        if isRLE && topDown { return nil }

        // Masks.
        var masks: (UInt32, UInt32, UInt32) = bitCount == 16 ? (0x7C00, 0x03E0, 0x001F) : (0xFF0000, 0xFF00, 0xFF)
        var paletteStart = 14 + Int(headerSize)
        if compression == 3 {
            guard reader.seek(to: 14 + 40), let r = reader.u32(), let g = reader.u32(), let b = reader.u32()
            else { return nil }
            masks = (r, g, b)
            if headerSize == 40 { paletteStart += 12 }
        }

        // Palette.
        var palette: [(UInt8, UInt8, UInt8)] = []
        if bitCount <= 8 {
            let full = 1 << bitCount
            let count = (1...full).contains(clrUsed) ? clrUsed : full
            guard reader.seek(to: paletteStart), let raw = reader.bytes(count * paletteEntrySize) else { return nil }
            palette.reserveCapacity(count)
            for i in 0..<count {
                let base = i * paletteEntrySize
                palette.append((raw[base + 2], raw[base + 1], raw[base]))
            }
        }
        let headerEnd = paletteStart + palette.count * paletteEntrySize
        let pixelOffset = (Int(offBits) >= headerEnd && Int(offBits) < bytes.count) ? Int(offBits) : headerEnd

        var out = [UInt8](repeating: 0, count: width * height * 4)
        func put(_ x: Int, _ y: Int, _ rgb: (UInt8, UInt8, UInt8)) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let i = (y * width + x) * 4
            out[i] = rgb.0; out[i + 1] = rgb.1; out[i + 2] = rgb.2; out[i + 3] = 255
        }
        func color(_ index: Int) -> (UInt8, UInt8, UInt8) {
            index >= 0 && index < palette.count ? palette[index] : (0, 0, 0)
        }

        if isRLE {
            // Unwritten pixels are palette index 0.
            let base = color(0)
            for y in 0..<height { for x in 0..<width { put(x, y, base) } }
            guard decodeRLE(bytes, offset: pixelOffset, width: width, height: height, rle4: compression == 2,
                            plot: { x, row, idx in put(x, height - 1 - row, color(idx)) })
            else { return nil }
        } else {
            let stride = ((width * bitCount + 31) / 32) * 4
            guard pixelOffset + stride * height <= bytes.count else { return nil }
            func channel(_ pixel: UInt32, _ mask: UInt32) -> UInt8 {
                guard mask != 0 else { return 0 }
                let v = UInt64((pixel & mask) >> UInt32(mask.trailingZeroBitCount))
                let maxV = (UInt64(1) << UInt64(mask.nonzeroBitCount)) - 1
                return UInt8(min(v * 255 / maxV, 255))
            }
            for r in 0..<height {
                let rowStart = pixelOffset + r * stride
                let y = topDown ? r : height - 1 - r
                for x in 0..<width {
                    let rgb: (UInt8, UInt8, UInt8)
                    switch bitCount {
                    case 1, 4, 8:
                        let bitIndex = x * bitCount
                        let byte = Int(bytes[rowStart + bitIndex / 8])
                        let shift = 8 - bitCount - (bitIndex % 8)
                        rgb = color((byte >> shift) & ((1 << bitCount) - 1))
                    case 16:
                        let p = rowStart + x * 2
                        let pixel = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8
                        rgb = (channel(pixel, masks.0), channel(pixel, masks.1), channel(pixel, masks.2))
                    case 24:
                        let p = rowStart + x * 3
                        rgb = (bytes[p + 2], bytes[p + 1], bytes[p])
                    default: // 32
                        let p = rowStart + x * 4
                        let pixel = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8
                            | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
                        rgb = (channel(pixel, masks.0), channel(pixel, masks.1), channel(pixel, masks.2))
                    }
                    put(x, y, rgb)
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Walks RLE8/RLE4 data; `plot(x, row, index)` uses row 0 = bottom. Returns false if data runs out early.
    private static func decodeRLE(_ bytes: [UInt8], offset: Int, width: Int, height: Int, rle4: Bool,
                                  plot: (Int, Int, Int) -> Void) -> Bool {
        var reader = ByteReader(bytes)
        guard reader.seek(to: offset) else { return false }
        var x = 0, y = 0
        while y < height {
            guard let n = reader.u8(), let b = reader.u8() else { return false }
            if n > 0 {
                for i in 0..<Int(n) {
                    let idx = rle4 ? (i % 2 == 0 ? Int(b >> 4) : Int(b & 0xF)) : Int(b)
                    if x < width { plot(x, y, idx) }
                    x += 1
                }
                continue
            }
            switch b {
            case 0: x = 0; y += 1
            case 1: return true
            case 2:
                guard let dx = reader.u8(), let dy = reader.u8() else { return false }
                x += Int(dx); y += Int(dy)
            default:
                let count = Int(b)
                let byteCount = rle4 ? (count + 1) / 2 : count
                guard let run = reader.bytes(byteCount) else { return false }
                for i in 0..<count {
                    let idx = rle4 ? (i % 2 == 0 ? Int(run[i / 2] >> 4) : Int(run[i / 2] & 0xF)) : Int(run[i])
                    if x < width { plot(x, y, idx) }
                    x += 1
                }
                if byteCount % 2 == 1 { _ = reader.u8() }
            }
        }
        return true
    }
}
