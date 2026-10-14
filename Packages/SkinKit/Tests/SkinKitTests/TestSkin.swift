import CoreGraphics
import Foundation
@testable import SkinKit

/// A skin with no .wsz behind it: every sheet in `SkinSprites.sheets`, each sprite rect filled with one flat
/// colour derived from the sprite's name, so a pixel at a layout position identifies the sprite that landed there.
enum TestSkin {
    /// Stable index of a sprite among all names, from 1.
    private static let indices: [String: Int] = {
        var result: [String: Int] = [:]
        for (offset, name) in SkinSprites.byName.keys.sorted().enumerated() { result[name] = offset + 1 }
        return result
    }()

    static func color(of spriteName: String) -> RGBColor {
        let index = indices[spriteName] ?? 0
        return RGBColor(red: UInt8(index & 0xFF), green: UInt8((index >> 8) & 0xFF), blue: 0x7F)
    }

    /// NUMS_EX is omitted by default so digits come from NUMBERS (`DIGIT_0`, not `DIGIT_0_EX`).
    static func make(omitting sheets: Set<String> = ["NUMS_EX"], region: SkinRegion = .empty) -> Skin {
        var images: [String: CGImage] = [:]
        for (sheet, sprites) in SkinSprites.sheets where !sheets.contains(sheet) {
            let width = sprites.map { $0.x + $0.width }.max() ?? 1
            let height = sprites.map { $0.y + $0.height }.max() ?? 1
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            context.setShouldAntialias(false)
            // Larger sprites first so a small sprite inside (or overlapping) a larger one keeps its own colour.
            let ordered = sprites.sorted { ($0.width * $0.height, $1.name) > ($1.width * $1.height, $0.name) }
            for sprite in ordered {
                let c = color(of: sprite.name)
                context.setFillColor(CGColor(
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    components: [CGFloat(c.red) / 255, CGFloat(c.green) / 255, CGFloat(c.blue) / 255, 1])!)
                context.fill(CGRect(x: sprite.x, y: height - sprite.y - sprite.height, width: sprite.width, height: sprite.height))
            }
            if let image = context.makeImage() { images[sheet] = image }
        }
        return Skin(sheets: images, visColors: VisRenderer.defaultColors, region: region, warnings: [])
    }

    /// RGBA of one pixel (premultiplied), top-left origin.
    static func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return bytes
    }

    /// All pixels as premultiplied RGBA8, row 0 at the top.
    static func bytes(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
