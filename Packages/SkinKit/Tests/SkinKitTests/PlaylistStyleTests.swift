import Foundation
import Testing
@testable import SkinKit

@Suite struct PlaylistStyleTests {
    private func rgb(_ hex: UInt32) -> RGBColor {
        RGBColor(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    private static let pika = "[Text]\r\nNormal=#FEC910\r\nCurrent=#FFFFFF\r\nNormalBG=#000000\r\nSelectedBG=#00639D\r\nFont=Tempus Sans ITC"

    @Test func defaultsMatchWebamp() {
        let d = PlaylistStyle.defaults
        #expect(d.normal == rgb(0x00FF00))
        #expect(d.current == rgb(0xFFFFFF))
        #expect(d.normalBackground == rgb(0x000000))
        #expect(d.selectedBackground == rgb(0x0000C6))
        #expect(d.font == "Arial")
    }

    @Test func parsesTheTextSectionWithAnyKeyCase() {
        let (style, fallbacks) = PlaylistStyleParser.parse(text: Self.pika)
        #expect(style.normal == rgb(0xFEC910))
        #expect(style.current == rgb(0xFFFFFF))
        #expect(style.normalBackground == rgb(0x000000))
        #expect(style.selectedBackground == rgb(0x00639D))
        #expect(style.font == "Tempus Sans ITC")
        #expect(fallbacks.isEmpty)
        let lower = PlaylistStyleParser.parse(text: "[TEXT]\nnormal=#010203\nSELECTEDBG=#040506").style
        #expect(lower.normal == rgb(0x010203))
        #expect(lower.selectedBackground == rgb(0x040506))
    }

    @Test func addsAMissingHashAndCutsLongColours() {
        let style = PlaylistStyleParser.parse(text: "[Text]\nNormal=FEC910\nCurrent=#FFFFFFFF").style
        #expect(style.normal == rgb(0xFEC910))
        #expect(style.current == rgb(0xFFFFFF))
    }

    @Test func missingKeysFallBackOneByOne() {
        let (style, fallbacks) = PlaylistStyleParser.parse(text: "[Text]\nNormal=#123456")
        #expect(style.normal == rgb(0x123456))
        #expect(style.current == PlaylistStyle.defaults.current)
        #expect(style.normalBackground == PlaylistStyle.defaults.normalBackground)
        #expect(style.selectedBackground == PlaylistStyle.defaults.selectedBackground)
        #expect(style.font == "Arial")
        #expect(fallbacks.isEmpty)
    }

    @Test func unusableColourFallsBackAndIsRecorded() {
        let (style, fallbacks) = PlaylistStyleParser.parse(text: "[Text]\nNormal=#GGGGGG\nCurrent=#FFF")
        #expect(style.normal == PlaylistStyle.defaults.normal)
        #expect(style.current == PlaylistStyle.defaults.current)
        #expect(fallbacks.count == 2)
        #expect(fallbacks[0].contains("normal"))
    }

    @Test func trailingSpacesCRLFAndArtAreTolerated() {
        let classic = "[Text]\r\nNormal=#83e736\r\nCurrent=#FFFFFF \r\nNormalBG=#000000 \r\nSelectedBG=#0000c6\r\nMbFG=#00FF00 \r\nMbBG=#000000 \r\nFont=Arial \r\n"
        let a = PlaylistStyleParser.parse(text: classic).style
        #expect(a.normal == rgb(0x83E736))
        #expect(a.current == rgb(0xFFFFFF))
        #expect(a.normalBackground == rgb(0))
        #expect(a.selectedBackground == rgb(0x0000C6))
        #expect(a.font == "Arial")
        let bag = "[Text]\r\nNormal=#405030\r\nCurrent=#E0FFC0\r\nNormalBG=#80A060\r\nSelectedBG=#7A9858\r\nMbBG=#80A060\r\nMbFG=#405030\r\nFont=Arial\r\n\r\n   //////Bag End's Gardener\\\\\\\\\\\\\\\r\n  |This file, like the arrangement|\r\n"
        let b = PlaylistStyleParser.parse(text: bag).style
        #expect(b.normal == rgb(0x405030))
        #expect(b.current == rgb(0xE0FFC0))
        #expect(b.normalBackground == rgb(0x80A060))
        #expect(b.selectedBackground == rgb(0x7A9858))
        #expect(b.font == "Arial")
    }

    @Test func noTextSectionGivesDefaults() {
        #expect(PlaylistStyleParser.parse(text: "").style == .defaults)
        #expect(PlaylistStyleParser.parse(text: "[Other]\nNormal=#123456").style == .defaults)
    }

    @Test func parserAttachesTheStyleAndRecordsAMissingFile() throws {
        let main = TestBitmaps.bmp(width: 275, height: 116, fill: RGBColor(red: 1, green: 2, blue: 3))
        let with = try SkinParser.parse(
            archive: SkinArchive(files: ["MAIN.BMP": main, "PLEDIT.TXT": Data(Self.pika.utf8)]))
        #expect(with.playlistStyle.normal == rgb(0xFEC910))
        #expect(!with.fallbacks.contains { $0.contains("pledit.txt") })
        let without = try SkinParser.parse(archive: SkinArchive(files: ["MAIN.BMP": main]))
        #expect(without.playlistStyle == .defaults)
        #expect(without.fallbacks.contains { $0.contains("pledit.txt missing") })
    }
}
