import CoreGraphics
import Testing
@testable import SkinKit

private func onePixel() -> CGImage {
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

struct DigitFontTests {
    @Test func prefersNumsExWhenPresent() {
        let skin = Skin(sheets: ["NUMBERS": onePixel(), "NUMS_EX": onePixel()], visColors: [], warnings: [])
        #expect(skin.usesNumsEx)
        #expect(skin.digitSpriteName(3) == "DIGIT_3")
        #expect(skin.resolve("DIGIT_3")?.sheet == "NUMS_EX")
        #expect(skin.minusFrame == CGRect(x: 38, y: 26, width: 9, height: 13))
        #expect(skin.resolve(skin.minusName)?.sheet == "NUMS_EX")
    }

    @Test func fallsBackToNumbers() {
        let skin = Skin(sheets: ["NUMBERS": onePixel()], visColors: [], warnings: [])
        #expect(!skin.usesNumsEx)
        #expect(skin.resolve("DIGIT_3")?.sheet == "NUMBERS")
        #expect(skin.minusFrame == CGRect(x: 38, y: 32, width: 5, height: 1))
        #expect(skin.resolve(skin.minusName)?.sheet == "NUMBERS")
    }
}
