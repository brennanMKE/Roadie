import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

private func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    }
    return bytes
}

/// A 155x18 TEXT sheet with each 5x6 cell filled with `r = column * 8, g = row * 80, b = 200`.
private func syntheticSheet() -> CGImage {
    let context = CGContext(
        data: nil, width: 155, height: 18, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for row in 0..<3 {
        for column in 0..<31 {
            context.setFillColor(
                CGColor(
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    components: [CGFloat(column * 8) / 255, CGFloat(row * 80) / 255, 200.0 / 255, 1])!)
            context.fill(CGRect(x: column * 5, y: 18 - (row + 1) * 6, width: 5, height: 6))
        }
    }
    return context.makeImage()!
}

/// The synthetic colour of the glyph for `character`.
private func glyphColour(_ character: String) -> [UInt8] {
    let name = TextFont.cells(for: character)[0]!
    let sprite = SkinSprites.byName[name]!.sprite
    return [UInt8(sprite.x / 5 * 8), UInt8(sprite.y / 6 * 80), 200, 255]
}

@Suite struct MiniTimeTests {
    private func status(_ transport: Transport, mode: TimeMode, elapsed: TimeInterval) -> MainWindowStatus {
        MainWindowStatus(
            transport: transport, timeMode: mode, elapsed: elapsed, duration: 200,
            bitrateKbps: nil, sampleRate: nil, channels: nil)
    }

    @Test func miniTimeCharactersFollowStatus() {
        #expect(MiniTime.characters(status(.playing, mode: .elapsed, elapsed: 61)) == [" ", "0", "1", "0", "1"])
        #expect(MiniTime.characters(status(.playing, mode: .remaining, elapsed: 61)) == ["-", "0", "2", "1", "9"])
        #expect(MiniTime.characters(status(.paused, mode: .elapsed, elapsed: 61)) == [" ", "0", "1", "0", "1"])
        #expect(MiniTime.characters(status(.stopped, mode: .elapsed, elapsed: 61)) == MiniTime.blank)
        #expect(MiniTime.characters(status(.stopped, mode: .remaining, elapsed: 61)) == MiniTime.blank)
        #expect(MiniTime.characters(status(.loading, mode: .elapsed, elapsed: 0)) == [" ", "0", "0", "0", "0"])
    }

    @Test func miniTimeImagePlacesGlyphsAtTheCellOffsets() throws {
        let skin = Skin(sheets: ["TEXT": syntheticSheet()], visColors: [], warnings: [])
        let image = try #require(skin.miniTimeImage(["-", "1", "2", "3", "4"]))
        #expect(image.width == 30 && image.height == 6)
        #expect(rgba(image, x: 1, y: 0) == glyphColour("-"))
        #expect(rgba(image, x: 7, y: 0) == glyphColour("1"))
        #expect(rgba(image, x: 12, y: 0) == glyphColour("2"))
        #expect(rgba(image, x: 20, y: 0) == glyphColour("3"))
        #expect(rgba(image, x: 25, y: 0) == glyphColour("4"))
        #expect(rgba(image, x: 29, y: 5) == glyphColour("4"))
        let blank = try #require(skin.miniTimeImage(MiniTime.blank))
        #expect(rgba(blank, x: 7, y: 0) == glyphColour(" "))
        let noText = Skin(sheets: ["MAIN": syntheticSheet()], visColors: [], warnings: [])
        #expect(noText.miniTimeImage(MiniTime.blank) == nil)
    }
}
