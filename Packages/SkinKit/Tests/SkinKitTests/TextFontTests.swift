import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

/// RGBA of one pixel, by drawing `image` into an RGBA8 context.
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
            // Same colour space as the context, so no colour matching shifts the values.
            context.setFillColor(
                CGColor(
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    components: [CGFloat(column * 8) / 255, CGFloat(row * 80) / 255, 200.0 / 255, 1])!)
            // CGContext origin is bottom-left; row 0 is the top of the sheet.
            context.fill(CGRect(x: column * 5, y: 18 - (row + 1) * 6, width: 5, height: 6))
        }
    }
    return context.makeImage()!
}

private func cellColour(row: Int, column: Int) -> [UInt8] { [UInt8(column * 8), UInt8(row * 80), 200, 255] }

@Suite struct TextFontTests {
    @Test func textSheetIsPorted() throws {
        #expect(SkinSprites.sheets["TEXT"]?.count == 69)
        func sprite(_ name: String) throws -> Sprite { try #require(SkinSprites.byName[name]).sprite }
        let a = try sprite("CHARACTER_97")
        #expect(a.x == 0 && a.y == 0 && a.width == 5 && a.height == 6)
        let ellipsis = try sprite("CHARACTER_8230")
        #expect(ellipsis.x == 50 && ellipsis.y == 6)
        let less = try sprite("CHARACTER_60")
        let bracket = try sprite("CHARACTER_91")
        #expect(less.x == 110 && less.y == 6)
        #expect(bracket.x == 110 && bracket.y == 6)
        let ring = try sprite("CHARACTER_197")
        #expect(ring.x == 0 && ring.y == 12)
        let space = try sprite("CHARACTER_32")
        #expect(space.x == 150 && space.y == 0)
        #expect(try #require(SkinSprites.byName["CHARACTER_97"]).sheet == "TEXT")
    }

    @Test func charactersFallBackLikeWebamp() {
        func name(_ s: String) -> String? { TextFont.spriteName(for: s.utf16.first!) }
        #expect(name("A") == "CHARACTER_97")
        #expect(name("\u{C9}") == "CHARACTER_101")  // É -> e
        #expect(name("\u{C5}") == "CHARACTER_97")  // Å -> a; the row-2 cell is unreachable, as in Webamp
        #expect(name("\u{DF}") == "CHARACTER_115")  // ß -> ss -> s
        #expect(name("\u{E6}") == "CHARACTER_97")  // æ -> ae -> a
        #expect(name("\u{FE}") == "CHARACTER_116")  // þ -> th -> t
        #expect(name("\u{2026}") == "CHARACTER_8230")
        #expect(name("<") == "CHARACTER_60")
        for blank in ["~", "|", "\u{20AC}", "\u{97F3}"] { #expect(name(blank) == nil, "\(blank)") }
        let blanks: [String?] = [nil, nil]
        #expect(TextFont.cells(for: "\u{1F3B5}") == blanks)
        let accented: [String?] = ["CHARACTER_101"]
        #expect(TextFont.cells(for: "e\u{301}") == accented)
        let lone: [String?] = [nil]
        #expect(TextFont.cells(for: "\u{301}") == lone)
    }

    @Test func textImageIsLaidOutInFivePixelCells() throws {
        let skin = Skin(sheets: ["TEXT": syntheticSheet()], visColors: [], warnings: [])
        let image = try #require(skin.textImage("a1~"))
        #expect(image.width == 15)
        #expect(image.height == 6)
        #expect(rgba(image, x: 0, y: 0) == cellColour(row: 0, column: 0))
        #expect(rgba(image, x: 4, y: 5) == cellColour(row: 0, column: 0))
        #expect(rgba(image, x: 5, y: 0) == cellColour(row: 1, column: 1))
        #expect(rgba(image, x: 14, y: 5)[3] == 0)
        let upper = try #require(skin.textImage("A"))
        let lower = try #require(skin.textImage("a"))
        for y in 0..<6 {
            for x in 0..<5 { #expect(rgba(upper, x: x, y: y) == rgba(lower, x: x, y: y)) }
        }
    }

    @Test func textImageNeedsATextSheetAndText() {
        let noText = Skin(sheets: ["MAIN": syntheticSheet()], visColors: [], warnings: [])
        #expect(noText.textImage("abc") == nil)
        let skin = Skin(sheets: ["TEXT": syntheticSheet()], visColors: [], warnings: [])
        #expect(skin.textImage("") == nil)
    }
}

@Suite struct MarqueeLayoutTests {
    @Test func loopsLongTextAndPadsShort() {
        #expect(MarqueeLayout.loopText("abc") == "abc" + String(repeating: " ", count: 28))
        #expect(!MarqueeLayout.isLong(String(repeating: "a", count: 30)))
        #expect(MarqueeLayout.isLong(String(repeating: "a", count: 31)))
        let long = String(repeating: "a", count: 31)
        #expect(MarqueeLayout.loopText(long) == long + "  ***  " + long)
        #expect(MarqueeLayout.loopText(long).utf16.count == 69)
    }

    @Test func stepOffsetWrapsLikeWebamp() {
        let long = String(repeating: "a", count: 31)
        #expect(MarqueeLayout.stepOffset(text: "short", step: 7, pixels: 40) == 0)
        #expect(MarqueeLayout.stepOffset(text: long, step: 1, pixels: 0) == 5)
        #expect(MarqueeLayout.stepOffset(text: long, step: 38, pixels: 0) == 0)
        #expect(MarqueeLayout.stepOffset(text: long, step: 0, pixels: -3) == 187)
        #expect(MarqueeLayout.stepOffset(text: long, step: 2, pixels: 7) == 17)
        #expect(MarqueeLayout.stepOffset(text: long, step: -1, pixels: 0) == 185)
    }

    @Test func countsDecomposedTextAsItRenders() {
        // 30 "e" + U+0301 pairs: 60 UTF-16 units decomposed, 30 cells after NFC, so it is short.
        let decomposed = String(repeating: "e\u{301}", count: 30)
        #expect(!MarqueeLayout.isLong(decomposed))
        #expect(TextFont.cells(for: MarqueeLayout.loopText(decomposed)).count == 31)
        // 31 pairs: long, and the period is (31 + 7) * 5 like the precomposed text.
        let long = String(repeating: "e\u{301}", count: 31)
        #expect(MarqueeLayout.isLong(long))
        #expect(MarqueeLayout.stepOffset(text: long, step: 38, pixels: 0) == 0)
        #expect(TextFont.cells(for: MarqueeLayout.loopText(long)).count == 69)
    }
}
