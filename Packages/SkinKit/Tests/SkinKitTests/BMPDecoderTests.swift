import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

/// Builds a BMP in memory: file header, BITMAPINFOHEADER (40) or BITMAPCOREHEADER (12), optional masks, palette, pixels.
private func makeBMP(width: Int, height: Int, bitCount: Int, compression: Int = 0, core: Bool = false,
                     masks: [UInt32]? = nil, palette: [RGBColor] = [], pixels: [UInt8]) -> Data {
    var d = [UInt8]()
    func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
    let headerSize = core ? 12 : 40
    let maskBytes = (masks?.count ?? 0) * 4
    let entry = core ? 3 : 4
    let offBits = 14 + headerSize + maskBytes + palette.count * entry
    d.append(contentsOf: Array("BM".utf8))
    u32(offBits + pixels.count); u32(0); u32(offBits)
    if core {
        u32(12); u16(width); u16(height); u16(1); u16(bitCount)
    } else {
        u32(40); u32(width); u32(height); u16(1); u16(bitCount); u32(compression); u32(pixels.count)
        u32(2835); u32(2835); u32(palette.count); u32(0)
    }
    for m in masks ?? [] { u32(Int(m)) }
    for c in palette {
        d.append(contentsOf: [c.blue, c.green, c.red])
        if !core { d.append(0) }
    }
    d.append(contentsOf: pixels)
    return Data(d)
}

private let red = RGBColor(red: 255, green: 0, blue: 0)
private let green = RGBColor(red: 0, green: 255, blue: 0)
private let blue = RGBColor(red: 0, green: 0, blue: 255)
private let white = RGBColor(red: 255, green: 255, blue: 255)
private let black = RGBColor(red: 0, green: 0, blue: 0)

private func px(_ image: CGImage, _ x: Int, _ y: Int) -> RGBColor { TestBitmaps.pixel(image, x: x, y: y) }

struct BMPDecoderTests {
    @Test func bmpDecodes1BitPaletted() throws {
        // 3x2, rows padded to 4 bytes. Bottom row (stored first): 1,0,1 ; top row: 0,1,0
        let data = makeBMP(width: 3, height: 2, bitCount: 1, palette: [black, white],
                           pixels: [0b1010_0000, 0, 0, 0, 0b0100_0000, 0, 0, 0])
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 1) == white)
        #expect(px(image, 1, 1) == black)
        #expect(px(image, 2, 1) == white)
        #expect(px(image, 0, 0) == black)
        #expect(px(image, 1, 0) == white)
    }

    @Test func bmpDecodes4BitPaletted() throws {
        let data = makeBMP(width: 3, height: 2, bitCount: 4, palette: [black, red, green, blue],
                           pixels: [0x12, 0x30, 0, 0, 0x01, 0x20, 0, 0])
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 1) == red)
        #expect(px(image, 1, 1) == green)
        #expect(px(image, 2, 1) == blue)
        #expect(px(image, 0, 0) == black)
        #expect(px(image, 1, 0) == red)
        #expect(px(image, 2, 0) == green)
    }

    @Test func bmpDecodes8BitPaletted() throws {
        let data = makeBMP(width: 3, height: 2, bitCount: 8, palette: [black, red, green, blue],
                           pixels: [1, 2, 3, 0, 3, 0, 9, 0])
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 1) == red)
        #expect(px(image, 2, 1) == blue)
        #expect(px(image, 0, 0) == blue)
        #expect(px(image, 1, 0) == black)
        #expect(px(image, 2, 0) == black) // index past palette
    }

    @Test func bmpDecodes24BitBottomUp() throws {
        // 2x2: row stride 8. bottom: red, green ; top: blue, white
        let data = makeBMP(width: 2, height: 2, bitCount: 24,
                           pixels: [0, 0, 255, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0])
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 1) == red)
        #expect(px(image, 1, 1) == green)
        #expect(px(image, 0, 0) == blue)
        #expect(px(image, 1, 0) == white)
    }

    @Test func bmpDecodes24BitTopDown() throws {
        var bytes = [UInt8](makeBMP(width: 2, height: 2, bitCount: 24,
                                    pixels: [0, 0, 255, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0]))
        // height = -2
        bytes[22] = 0xFE; bytes[23] = 0xFF; bytes[24] = 0xFF; bytes[25] = 0xFF
        let image = try #require(BMPDecoder.decode(Data(bytes)))
        #expect(px(image, 0, 0) == red)
        #expect(px(image, 1, 0) == green)
        #expect(px(image, 0, 1) == blue)
        #expect(px(image, 1, 1) == white)
    }

    @Test func bmpDecodes32Bit() throws {
        let data = makeBMP(width: 2, height: 1, bitCount: 32, pixels: [0, 0, 255, 0, 255, 128, 0, 0])
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 0) == red)
        #expect(px(image, 1, 0) == RGBColor(red: 0, green: 128, blue: 255))
    }

    @Test func bmpDecodes16Bit555() throws {
        // red 0x7C00, blue 0x001F; stride 4
        let data = makeBMP(width: 2, height: 2, bitCount: 16, pixels: [0x00, 0x7C, 0x1F, 0x00, 0xE0, 0x03, 0xFF, 0x7F])
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 1) == red)
        #expect(px(image, 1, 1) == blue)
        #expect(px(image, 0, 0) == green)
        #expect(px(image, 1, 0) == white)
    }

    @Test func bmpDecodes16BitBitfields565() throws {
        let data = makeBMP(width: 2, height: 2, bitCount: 16, compression: 3, masks: [0xF800, 0x07E0, 0x001F],
                           pixels: [0x00, 0xF8, 0xE0, 0x07, 0x1F, 0x00, 0x00, 0x00])
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 1) == red)
        #expect(px(image, 1, 1) == green)
        #expect(px(image, 0, 0) == blue)
        #expect(px(image, 1, 0) == black)
    }

    @Test func bmpDecodesRLE8() throws {
        // 4x3 bottom-up. palette: 0 black, 1 red, 2 green, 3 blue
        let rle: [UInt8] = [
            2, 1,                 // row0: red red
            0, 0,                 // EOL
            0, 3, 2, 3, 1, 0,     // row1: absolute 3 pixels green blue red + pad
            0, 2, 1, 1,           // delta: x=4,y=2
            0, 0,                 // EOL -> x=0,y=3? (y=2 then EOL -> y=3)
            0, 1,                 // EOB
        ]
        let data = makeBMP(width: 4, height: 3, bitCount: 8, compression: 1, palette: [black, red, green, blue],
                           pixels: rle)
        let image = try #require(BMPDecoder.decode(data))
        // row0 is bottom (y=2)
        #expect(px(image, 0, 2) == red)
        #expect(px(image, 1, 2) == red)
        #expect(px(image, 2, 2) == black)
        #expect(px(image, 0, 1) == green)
        #expect(px(image, 1, 1) == blue)
        #expect(px(image, 2, 1) == red)
        #expect(px(image, 3, 1) == black)
        #expect(px(image, 0, 0) == black)
    }

    @Test func bmpDecodesRLE4() throws {
        let rle: [UInt8] = [
            4, 0x12,              // row0: 1 2 1 2
            0, 0,
            0, 3, 0x31, 0x20,     // row1: absolute 3 = 3 1 2 (2 bytes, even, no pad)
            0, 1,
        ]
        let data = makeBMP(width: 4, height: 2, bitCount: 4, compression: 2, palette: [black, red, green, blue],
                           pixels: rle)
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 1) == red)
        #expect(px(image, 1, 1) == green)
        #expect(px(image, 2, 1) == red)
        #expect(px(image, 3, 1) == green)
        #expect(px(image, 0, 0) == blue)
        #expect(px(image, 1, 0) == red)
        #expect(px(image, 2, 0) == green)
        #expect(px(image, 3, 0) == black)
    }

    @Test func bmpDecodesCoreHeader() throws {
        let palette = [black, red, green, blue] + [RGBColor](repeating: white, count: 252)
        let data = makeBMP(width: 3, height: 2, bitCount: 8, core: true, palette: palette,
                           pixels: [1, 2, 3, 0, 3, 2, 1, 0])
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 0, 1) == red)
        #expect(px(image, 2, 1) == blue)
        #expect(px(image, 0, 0) == blue)
        #expect(px(image, 2, 0) == red)
    }

    @Test func bmpRLEOverrunIsClipped() throws {
        let rle: [UInt8] = [
            200, 1,               // run far past width
            0, 2, 255, 255,       // delta past the top
            5, 2,
        ]
        let data = makeBMP(width: 4, height: 2, bitCount: 8, compression: 1, palette: [black, red, green],
                           pixels: rle)
        let image = try #require(BMPDecoder.decode(data))
        #expect(px(image, 3, 1) == red)
        #expect(px(image, 0, 0) == black)
    }

    @Test func bmpRejectsGarbage() {
        var gen = SystemRandomNumberGenerator()
        let random = Data((0..<256).map { _ in UInt8.random(in: 0...255, using: &gen) })
        #expect(BMPDecoder.decode(random) == nil)
        #expect(BMPDecoder.decode(Data()) == nil)
        #expect(BMPDecoder.decode(Data("BM".utf8)) == nil)
    }

    @Test func bmpRejectsTruncatedData() {
        let full = TestBitmaps.bmp(width: 4, height: 4, fill: red)
        #expect(BMPDecoder.decode(full) != nil)
        #expect(BMPDecoder.decode(full.prefix(full.count - 5)) == nil)
        #expect(BMPDecoder.decode(full.prefix(30)) == nil)
        let rle = makeBMP(width: 4, height: 2, bitCount: 8, compression: 1, palette: [black, red], pixels: [2, 1, 0])
        #expect(BMPDecoder.decode(rle) == nil)
    }

    @Test func bmpRejectsForgedDimensions() {
        func forged(_ w: Int32, _ h: Int32) -> Data {
            var bytes = [UInt8](makeBMP(width: 1, height: 1, bitCount: 24, pixels: [0, 0, 0, 0]))
            let wb = UInt32(bitPattern: w), hb = UInt32(bitPattern: h)
            for i in 0..<4 {
                bytes[18 + i] = UInt8((wb >> (8 * UInt32(i))) & 0xFF)
                bytes[22 + i] = UInt8((hb >> (8 * UInt32(i))) & 0xFF)
            }
            return Data(bytes)
        }
        #expect(BMPDecoder.decode(forged(1, 1)) != nil)
        #expect(BMPDecoder.decode(forged(100_000, 100_000)) == nil)
        #expect(BMPDecoder.decode(forged(0, 1)) == nil)
        #expect(BMPDecoder.decode(forged(1, Int32.min)) == nil)
        #expect(BMPDecoder.decode(forged(4097, 1)) == nil)
    }

    @Test func bitmapLoaderFallsBackWhenPrimaryFails() throws {
        let data = TestBitmaps.bmp(width: 3, height: 2, fill: green)
        let image = try #require(BitmapLoader.image(from: data, primary: { _ in nil }))
        #expect(px(image, 0, 0) == green)
        #expect(px(image, 2, 1) == green)
        #expect(BitmapLoader.image(from: Data([1, 2, 3, 4, 5])) == nil)
    }
}
