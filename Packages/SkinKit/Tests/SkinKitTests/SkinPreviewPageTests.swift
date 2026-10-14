import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SkinKit

struct SkinPreviewPageTests {
    private func readmeSkin(named name: String = "test.wsz", extra: [(String, Data)] = []) throws -> URL {
        try ZipFixtures.zip(ZipFixtures.skinFiles(extra: extra), named: name)
    }

    @Test func pageReferencesMainAttachment() throws {
        let page = SkinPreviewPage.make(url: try readmeSkin(named: "Plain Skin.wsz"))
        let png = try #require(page.attachments["main"])
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1100 && image.height == 464)
        #expect(page.html.contains("cid:main"))
        #expect(page.html.contains("Plain Skin"))
        #expect(page.html.contains("image-rendering"))
        #expect(page.title == "Plain Skin")
    }

    @Test func escapesTitleAndReadme() throws {
        let url = try readmeSkin(named: "A & B <skin>.wsz", extra: [("readme.txt", Data("<script>alert(1)</script>".utf8))])
        let page = SkinPreviewPage.make(url: url)
        #expect(page.html.contains("A &amp; B &lt;skin&gt;"))
        #expect(page.html.contains("&lt;script&gt;"))
        #expect(!page.html.contains("<script>") && !page.html.contains("A & B <skin>"))
    }

    @Test func readmePrefersReadmeTxtAndCaps() throws {
        let big = Data(String(repeating: "Q", count: 30 * 1024).utf8)
        let url = try readmeSkin(extra: [
            ("other.txt", Data("OTHERTEXT".utf8)), ("readme.txt", big), ("viscolor.txt", Data("VISCOLORTEXT".utf8)),
            ("pledit.txt", Data("PLEDITTEXT".utf8)), ("region.txt", Data("REGIONTEXT".utf8)),
        ])
        let html = SkinPreviewPage.make(url: url).html
        #expect(!html.contains("OTHERTEXT"))
        #expect(!html.contains("VISCOLORTEXT") && !html.contains("PLEDITTEXT") && !html.contains("REGIONTEXT"))
        #expect(html.contains("…"))
        let run = html.filter { $0 == "Q" }.count
        #expect(run == SkinPreviewPage.readmeLimit)
    }

    @Test func modernSkinGivesCantPreviewPage() throws {
        let url = try ZipFixtures.zip([("skin.xml", Data("<skin/>".utf8))], named: "Modern One.wsz")
        let page = SkinPreviewPage.make(url: url)
        #expect(page.title == "Modern One")
        #expect(page.html.contains("Can't preview") && page.html.contains("Modern"))
        #expect(page.attachments.isEmpty)
    }

    @Test func unreadableFileGivesCantPreviewPage() throws {
        let url = ZipFixtures.tempURL("x.wsz")
        try Data("not a zip file at all, just text\n".utf8).write(to: url)
        let page = SkinPreviewPage.make(url: url)
        #expect(page.html.contains("Unreadable archive"))
        #expect(page.attachments.isEmpty)
    }

    @Test func warningsAreListed() throws {
        let skin = TestSkin.make(omitting: ["NUMS_EX", "CBUTTONS"])
        let files = skin.sheets.compactMap { name, image in PNGWriter.data(image).map { ("\(name.lowercased()).png", $0) } }
        let page = SkinPreviewPage.make(url: try ZipFixtures.zip(files))
        #expect(page.html.contains("<li>Missing cbuttons.bmp</li>"))
    }
}
