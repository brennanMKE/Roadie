import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

struct SkinKitTests {
    @Test func spriteTableIsPorted() {
        #expect(SkinSprites.byName["MAIN_WINDOW_BACKGROUND"]?.sprite.rect == CGRect(x: 0, y: 0, width: 275, height: 116))
        #expect(SkinSprites.byName["MAIN_PLAY_BUTTON"]?.sheet == "CBUTTONS")
    }

    @Test func archiveLookupIsCaseInsensitive() {
        let archive = SkinArchive(files: ["MAIN.BMP": Data([1])])
        #expect(archive.file("main", extensions: ["bmp"]) == Data([1]))
    }

    @Test func modernSkinIsRejected() {
        #expect(throws: SkinError.self) {
            try SkinParser.parse(archive: SkinArchive(files: ["skin.xml": Data()]))
        }
    }

    @Test func visColorsTolerateCommentsAndCRLF() {
        let text = "24,33,41, // background\r\n255 255 255\r\n"
        let colors = VisColorParser.parse(Data(text.utf8))
        #expect(colors.count == 24)
        #expect(colors[0] == RGBColor(red: 24, green: 33, blue: 41))
        #expect(colors[1] == RGBColor(red: 255, green: 255, blue: 255))
        #expect(colors[2] == VisColorParser.defaults[2])
    }

    /// A `width` x `height` RGB image whose 15-row band `n` is filled with gray `10 + n`.
    private func bandedSheet(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for band in 0..<(height + 14) / 15 {
            let gray = CGFloat(10 + band) / 255
            context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
            // CGContext's origin is bottom-left; band 0 is the top 15 rows.
            context.fill(CGRect(x: 0, y: height - (band + 1) * 15, width: width, height: 15))
        }
        return context.makeImage()!
    }

    @Test func frameCropReadsThirteenRows() {
        let skin = Skin(sheets: ["VOLUME": bandedSheet(width: 68, height: 420)], visColors: [], warnings: [])
        let frame13 = skin.image(for: "MAIN_VOLUME_BACKGROUND", frame: 13)
        #expect(frame13?.width == 68 && frame13?.height == 13)
        #expect(frame13.map { TestBitmaps.pixel($0, x: 0, y: 0) } == RGBColor(red: 23, green: 23, blue: 23))
        #expect(frame13.map { TestBitmaps.pixel($0, x: 67, y: 12) } == RGBColor(red: 23, green: 23, blue: 23))
        let frame27 = skin.image(for: "MAIN_VOLUME_BACKGROUND", frame: 27)
        #expect(frame27?.width == 68 && frame27?.height == 13)
        // The balance slider with no balance.bmp crops frames from the volume sheet (#0020 fallback).
        let balance = skin.image(for: "MAIN_BALANCE_BACKGROUND", frame: 2)
        #expect(balance?.width == 38 && balance?.height == 13)
        #expect(balance.map { TestBitmaps.pixel($0, x: 0, y: 0) } == RGBColor(red: 12, green: 12, blue: 12))
        // A sheet that ends before the frame gives nil, not a crash.
        let short = Skin(sheets: ["VOLUME": bandedSheet(width: 68, height: 405)], visColors: [], warnings: [])
        #expect(short.image(for: "MAIN_VOLUME_BACKGROUND", frame: 27) == nil)
        #expect(short.image(for: "MAIN_VOLUME_BACKGROUND", frame: 26) != nil)
    }

    /// Set SKIN_CORPUS_DIR to a folder of .wsz files to run against the real corpus.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKIN_CORPUS_DIR"] != nil))
    func corpusNeverCrashes() throws {
        let root = URL(filePath: ProcessInfo.processInfo.environment["SKIN_CORPUS_DIR"]!)
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wsz" }
        for url in urls { _ = try? SkinParser.parse(url: url) }
    }
}
