import Foundation
import Testing

@testable import SkinKit
@testable import SkinLibrary

@Suite struct SkinReadmeTests {
    private func archive(_ files: [String: String]) -> SkinArchive {
        SkinArchive(files: files.mapValues { Data($0.utf8) })
    }

    @Test func prefersReadmeOverOtherText() {
        let text = SkinReadme.extract(from: archive(["notes.txt": "a much longer set of notes than the readme", "Readme.txt": "hello"]))
        #expect(text == "hello")
    }

    @Test func ignoresKnownConfigFiles() {
        let files = ["pledit.txt": "x", "viscolor.txt": "y", "region.txt": "z", "winampmb.txt": "w", "pledit_example.txt": "v"]
        #expect(SkinReadme.extract(from: archive(files)) == nil)
    }

    @Test func fallsBackToLargestText() {
        let text = SkinReadme.extract(from: archive(["MatrixCode.txt": "the matrix code readout", "info.nfo": "tiny"]))
        #expect(text == "the matrix code readout")
    }

    @Test func noTextMeansNil() {
        #expect(SkinReadme.extract(from: archive(["main.bmp": "x"])) == nil)
    }

    @Test func decodesUTF8ThenWindows1252() {
        #expect(SkinReadme.decode(Data([0x93, 0x68, 0x69, 0x94])) == "\u{201C}hi\u{201D}")
        #expect(SkinReadme.decode(Data("caf\u{E9}".utf8)) == "caf\u{E9}")
    }

    @Test func normalizesLineEndingsAndCapsAt64KiB() {
        let text = SkinReadme.extract(from: archive(["readme.txt": "a\r\nb\rc\0d"]))
        #expect(text == "a\nb\ncd")
        let big = String(repeating: "x", count: 100 * 1024)
        #expect(SkinReadme.extract(from: archive(["readme.txt": big]))?.count == 65_536)
    }
}
