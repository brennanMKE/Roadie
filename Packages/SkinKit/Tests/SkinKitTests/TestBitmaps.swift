import CoreGraphics
import Foundation
@testable import SkinKit

enum TestBitmaps {
    /// 24-bit bottom-up BMP (54-byte header, BGR rows padded to 4 bytes), solid `fill`. ImageIO decodes it.
    static func bmp(width: Int, height: Int, fill: RGBColor) -> Data {
        let rowSize = (width * 3 + 3) / 4 * 4
        let imageSize = rowSize * height
        var data = Data()
        func u16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        data.append(contentsOf: Array("BM".utf8))
        u32(54 + imageSize); u32(0); u32(54)
        u32(40); u32(width); u32(height); u16(1); u16(24); u32(0); u32(imageSize); u32(2835); u32(2835); u32(0); u32(0)
        var row = [UInt8]()
        for _ in 0..<width { row.append(contentsOf: [fill.blue, fill.green, fill.red]) }
        row.append(contentsOf: [UInt8](repeating: 0, count: rowSize - width * 3))
        for _ in 0..<height { data.append(contentsOf: row) }
        return data
    }

    /// Reads one pixel by drawing `image` into an RGBA8 CGContext.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> RGBColor {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return RGBColor(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
}
