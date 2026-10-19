import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

private func size(_ image: CGImage?) -> [Int]? { image.map { [$0.width, $0.height] } }
private func isLit(_ image: CGImage, _ x: Int, _ y: Int) -> Bool { TestBitmaps.pixel(image, x: x, y: y).green > 128 }
private func litPattern(_ image: CGImage) -> [Bool] {
    (0..<image.height).flatMap { y in (0..<image.width).map { x in isLit(image, x, y) } }
}
private func crop(_ sheet: CGImage, _ spriteName: String) -> CGImage? {
    SkinSprites.byName[spriteName].flatMap { sheet.cropping(to: $0.sprite.rect) }
}
private func mainOnly(_ extra: [String: Data] = [:]) throws -> Skin {
    var files = extra
    files["main.bmp"] = TestBitmaps.bmp(width: 275, height: 116, fill: RGBColor(red: 255, green: 0, blue: 0))
    return try SkinParser.parse(archive: SkinArchive(files: files))
}

struct GeneratedBaseSkinTests {
    @Test func missingSheetsFillFromGeneratedBase() throws {
        let url = try ZipFixtures.zip(ZipFixtures.skinFiles(omitting: ["NUMS_EX", "EQMAIN", "PLEDIT", "CBUTTONS"]))
        let skin = try SkinParser.parse(url: url)
        for name in ["EQMAIN", "PLEDIT", "CBUTTONS"] {
            let expected = GeneratedBaseSkin.size(of: name)
            #expect(size(skin.sheets[name]) == [expected.width, expected.height])
            #expect(skin.generatedSheets.contains(name))
            #expect(skin.fallbacks.contains("\(name.lowercased()).bmp missing; generated base"))
            #expect(skin.warnings.contains("Missing \(name.lowercased()).bmp"))
        }
        #expect(size(skin.image(for: "EQ_WINDOW_BACKGROUND")) == [275, 116])
        #expect(size(skin.image(for: "MAIN_PLAY_BUTTON")) == [23, 18])
    }

    @Test func completeSkinUsesNoGeneratedBase() throws {
        let skin = try SkinParser.parse(url: ZipFixtures.zip(ZipFixtures.skinFiles()))
        #expect(skin.generatedSheets.isEmpty)
        #expect(!skin.fallbacks.contains { $0.contains("generated base") })
        let main = try #require(skin.sheets["MAIN"])
        #expect(TestBitmaps.pixel(main, x: 5, y: 5) == TestSkin.color(of: "MAIN_WINDOW_BACKGROUND"))
    }

    @Test func generatedBaseCoversEverySprite() throws {
        for name in GeneratedBaseSkin.sheetNames {
            let image = try #require(GeneratedBaseSkin.sheet(name))
            let expected = GeneratedBaseSkin.size(of: name)
            #expect(size(image) == [expected.width, expected.height])
            for sprite in SkinSprites.sheets[name] ?? [] {
                #expect(sprite.x + sprite.width <= image.width && sprite.y + sprite.height <= image.height)
            }
        }
        let skin = try mainOnly()
        for name in skin.generatedSheets {
            for sprite in SkinSprites.sheets[name] ?? [] {
                #expect(skin.image(for: sprite.name) != nil, "\(sprite.name)")
            }
        }
        #expect(skin.generatedSheets.contains("CBUTTONS"))
    }

    @Test func generatedDigitsAreDistinct() throws {
        let sheet = try #require(GeneratedBaseSkin.sheet("NUMBERS"))
        let patterns = try (0...9).map { try litPattern(#require(crop(sheet, "DIGIT_\($0)"))) }
        #expect(Set(patterns).count == 10)
        #expect(try litPattern(#require(crop(sheet, "MINUS_SIGN"))).contains(true))
        #expect(try !litPattern(#require(crop(sheet, "NO_MINUS_SIGN"))).contains(true))
    }

    @Test func generatedTextHasGlyphs() throws {
        let sheet = try #require(GeneratedBaseSkin.sheet("TEXT"))
        #expect(try litPattern(#require(crop(sheet, "CHARACTER_97"))).contains(true))
        #expect(try !litPattern(#require(crop(sheet, "CHARACTER_32"))).contains(true))
    }

    @Test func undecodableSheetFallsBackToGeneratedBase() throws {
        let skin = try mainOnly(["cbuttons.bmp": Data("junk".utf8)])
        #expect(skin.warnings.contains("Undecodable cbuttons.bmp"))
        #expect(skin.fallbacks.contains("cbuttons.bmp undecodable; generated base"))
        #expect(skin.sheets["CBUTTONS"] != nil)
    }

    @Test func noSheetsStillThrowsNoBitmaps() {
        do {
            _ = try SkinParser.parse(archive: SkinArchive(files: ["readme.txt": Data("x".utf8)]))
            Issue.record("expected noBitmaps")
        } catch {
            guard case .noBitmaps = error else { Issue.record("unexpected \(error)"); return }
        }
    }
}
