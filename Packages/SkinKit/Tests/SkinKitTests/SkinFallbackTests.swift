import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

private let red = RGBColor(red: 255, green: 0, blue: 0)
private let blue = RGBColor(red: 0, green: 0, blue: 255)

/// Builds a skin from solid-colour sheets; `sheets` maps file name to (width, height, fill).
private func makeSkin(_ sheets: [String: (Int, Int, RGBColor)], extra: [String: Data] = [:]) throws -> Skin {
    var files = extra
    files["main.bmp"] = TestBitmaps.bmp(width: 275, height: 116, fill: red)
    for (name, spec) in sheets { files[name] = TestBitmaps.bmp(width: spec.0, height: spec.1, fill: spec.2) }
    return try SkinParser.parse(archive: SkinArchive(files: files))
}

private func size(_ image: CGImage?) -> [Int]? { image.map { [$0.width, $0.height] } }
private func mentions(_ lines: [String], _ text: String) -> Bool { lines.contains { $0.contains(text) } }

struct SkinFallbackTests {
    @Test func balanceFallsBackToVolume() throws {
        let skin = try makeSkin(["volume.bmp": (68, 433, red)])
        let background = skin.image(for: "MAIN_BALANCE_BACKGROUND")
        #expect(size(background) == [38, 420])
        #expect(background.map { TestBitmaps.pixel($0, x: 5, y: 5) } == red)
        let resolved = skin.resolve("MAIN_BALANCE_BACKGROUND")
        #expect(resolved?.sheet == "VOLUME")
        #expect(resolved?.rect == CGRect(x: 0, y: 0, width: 38, height: 420))
        for name in ["MAIN_BALANCE_THUMB", "MAIN_BALANCE_THUMB_ACTIVE"] {
            let thumb = skin.image(for: name)
            #expect(size(thumb) == [14, 11])
            #expect(thumb.map { TestBitmaps.pixel($0, x: 1, y: 1) } == red)
        }
        #expect(!mentions(skin.warnings, "balance"))
        #expect(skin.fallbacks.contains("balance.bmp missing; balance slider uses volume.bmp"))
    }

    @Test func balanceSheetWinsWhenPresent() throws {
        let skin = try makeSkin(["volume.bmp": (68, 420, red), "balance.bmp": (47, 420, blue)])
        let background = skin.image(for: "MAIN_BALANCE_BACKGROUND")
        #expect(background.map { TestBitmaps.pixel($0, x: 5, y: 5) } == blue)
        let resolved = skin.resolve("MAIN_BALANCE_BACKGROUND")
        #expect(resolved?.sheet == "BALANCE")
        #expect(resolved?.rect == CGRect(x: 9, y: 0, width: 38, height: 420))
        #expect(!mentions(skin.fallbacks, "balance"))
    }

    @Test func balanceWithoutVolumeWarnsOnceForVolume() throws {
        let skin = try makeSkin(["balance.bmp": (47, 420, blue)])
        let background = skin.image(for: "MAIN_BALANCE_BACKGROUND")
        #expect(background.map { TestBitmaps.pixel($0, x: 5, y: 5) } == blue)
        #expect(skin.image(for: "MAIN_VOLUME_BACKGROUND") == nil)
        #expect(skin.warnings.filter { $0.contains("volume") } == ["Missing volume.bmp"])
    }

    @Test func numsExWinsWhenPresent() throws {
        let skin = try makeSkin(["numbers.bmp": (99, 13, red), "nums_ex.bmp": (108, 13, blue)])
        #expect(skin.usesNumsEx)
        for name in ["DIGIT_0", "DIGIT_0_EX"] {
            let digit = skin.image(for: name)
            #expect(size(digit) == [9, 13])
            #expect(digit.map { TestBitmaps.pixel($0, x: 2, y: 2) } == blue)
        }
        #expect(size(skin.image(for: "MINUS_SIGN")) == [9, 13])
        let resolved = skin.resolve("NO_MINUS_SIGN")
        #expect(resolved?.sheet == "NUMS_EX")
        #expect(resolved?.rect == CGRect(x: 90, y: 0, width: 9, height: 13))
    }

    @Test func digitsFallBackToNumbersWithoutNumsEx() throws {
        let skin = try makeSkin(["numbers.bmp": (99, 13, red)])
        #expect(!skin.usesNumsEx)
        let digit = skin.image(for: "DIGIT_5_EX")
        #expect(size(digit) == [9, 13])
        #expect(digit.map { TestBitmaps.pixel($0, x: 2, y: 2) } == red)
        #expect(size(skin.image(for: "MINUS_SIGN_EX")) == [5, 1])
        #expect(!mentions(skin.warnings, "nums_ex"))
        #expect(skin.fallbacks.contains("nums_ex.bmp missing; digits use numbers.bmp"))
    }

    @Test func digitsFallBackToNumsExWithoutNumbers() throws {
        let skin = try makeSkin(["nums_ex.bmp": (108, 13, blue)])
        #expect(skin.usesNumsEx)
        let digit = skin.image(for: "DIGIT_5")
        #expect(size(digit) == [9, 13])
        #expect(digit.map { TestBitmaps.pixel($0, x: 2, y: 2) } == blue)
        #expect(!mentions(skin.warnings, "numbers"))
        #expect(skin.fallbacks.contains("numbers.bmp missing; digits use nums_ex.bmp"))
    }

    @Test func noNumberSheetWarnsOnce() throws {
        let skin = try makeSkin([:])
        #expect(skin.image(for: "DIGIT_0") == nil)
        #expect(skin.warnings.filter { $0.contains("numbers") } == ["Missing numbers.bmp and nums_ex.bmp"])
    }

    @Test func eqMaximizeActiveFallsBackToEqmain() throws {
        let skin = try makeSkin(["eqmain.bmp": (275, 315, red)])
        let button = skin.image(for: "EQ_MAXIMIZE_BUTTON_ACTIVE")
        #expect(size(button) == [9, 9])
        #expect(button.map { TestBitmaps.pixel($0, x: 1, y: 1) } == red)
        let resolved = skin.resolve("EQ_MAXIMIZE_BUTTON_ACTIVE")
        #expect(resolved?.sheet == "EQMAIN")
        #expect(resolved?.rect == CGRect(x: 254, y: 152, width: 9, height: 9))
        #expect(!mentions(skin.warnings, "eq_ex"))
    }

    @Test func genAndEqExAreOptional() throws {
        let skin = try makeSkin([:])
        #expect(!mentions(skin.warnings, "gen.bmp"))
        #expect(!mentions(skin.warnings, "eq_ex.bmp"))
        #expect(mentions(skin.fallbacks, "gen.bmp"))
        #expect(mentions(skin.fallbacks, "eq_ex.bmp"))
    }

    @Test func fallbackCropClampsToSheetBounds() throws {
        let skin = try makeSkin(["volume.bmp": (68, 419, red)])
        #expect(size(skin.image(for: "MAIN_BALANCE_BACKGROUND")) == [38, 419])
    }

    // MARK: viscolor

    @Test func visColorsDefaultToWebampBaseSkin() throws {
        let skin = try makeSkin([:])
        #expect(skin.visColors.count == 24)
        #expect(skin.visColors == VisColorParser.defaults)
        #expect(skin.visColors[2] == RGBColor(red: 239, green: 49, blue: 16))
        #expect(skin.visColors[23] == RGBColor(red: 150, green: 150, blue: 150))
        #expect(!mentions(skin.warnings, "viscolor"))
        #expect(skin.fallbacks.contains("viscolor.txt missing; Webamp defaults"))
    }

    @Test func visColorsShortFileKeepsDefaultsForTheRest() throws {
        let text = String(repeating: "1,2,3\n", count: 22)
        let skin = try makeSkin([:], extra: ["viscolor.txt": Data(text.utf8)])
        let c = RGBColor(red: 1, green: 2, blue: 3)
        #expect(skin.visColors[0...21].allSatisfy { $0 == c })
        #expect(skin.visColors[22] == RGBColor(red: 148, green: 156, blue: 165))
        #expect(skin.visColors[23] == RGBColor(red: 150, green: 150, blue: 150))
        #expect(skin.fallbacks.contains("viscolor.txt has 22 of 24 colours; defaults for 22\u{2013}23"))
        #expect(!mentions(skin.warnings, "viscolor"))
    }

    @Test func visColorsSkipNonColorLinesWithoutConsumingAnIndex() {
        let text = "// header\r\n1,2,3\r\n\r\n4 5 6 // grid\r\ncolor 7 = 9,9,9\r\n"
        let parsed = VisColorParser.parseCounted(Data(text.utf8))
        #expect(parsed.colors[0] == RGBColor(red: 1, green: 2, blue: 3))
        #expect(parsed.colors[1] == RGBColor(red: 4, green: 5, blue: 6))
        #expect(parsed.colors[2] == VisColorParser.defaults[2])
        #expect(parsed.parsedCount == 2)
    }

    @Test func visColorsIgnoreLinesPast24() {
        let text = (1...30).map { "\($0),0,0" }.joined(separator: "\n")
        let colors = VisColorParser.parse(Data(text.utf8))
        #expect(colors.count == 24)
        #expect(colors[23] == RGBColor(red: 24, green: 0, blue: 0))
    }

    @Test func visColorsClampValues() {
        let colors = VisColorParser.parse(Data("300,0,0".utf8))
        #expect(colors[0] == RGBColor(red: 255, green: 0, blue: 0))
    }

    /// Set SKIN_SAMPLES_DIR to a folder of .wsz files; every one must parse without warnings.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKIN_SAMPLES_DIR"] != nil))
    func sampleSkinsAreOk() throws {
        let root = URL(filePath: ProcessInfo.processInfo.environment["SKIN_SAMPLES_DIR"]!)
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wsz" }
        #expect(!urls.isEmpty)
        for url in urls {
            let skin = try SkinParser.parse(url: url)
            #expect(skin.warnings.isEmpty, "\(url.lastPathComponent): \(skin.warnings) fallbacks: \(skin.fallbacks)")
            #expect(skin.visColors.count == 24, "\(url.lastPathComponent)")
        }
    }
}
