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
        #expect(colors == [RGBColor(red: 24, green: 33, blue: 41), RGBColor(red: 255, green: 255, blue: 255)])
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
