import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

private let pika = """
    [Normal]\r
    NumPoints = 16\r
    PointList = 4,0, 270,0, 272,1, 273,2, 275,5, 275,110, 273,113, 272,114, 269,116, 5,116, 2,114, 1,113, 0,111, 0,4, 1,2, 2,1\r
    \r
    [Equalizer]\r
    NumPoints = 16\r
    PointList = 4,0, 270,0, 272,1, 273,2, 275,5, 275,110, 273,113, 272,114, 269,116, 5,116, 2,114, 1,113, 0,111, 0,4, 1,2, 2,1\r

    """

private let sony = """
    [Normal]
    NumPoints=28
    PointList=3,0, 48,0, 48,1, 226,1, 226,0, 272,0, ,275,3, 275,29, 273,31, 273,84, 275,86, 275,110, 272,113, 265,113, 265,116, 226,116, 226,113, 49,113, 49,116, 10,116, 10,113, 3,113, 0,110, 0,86, 2,84, 2,31, 0,29, 0,3,

    [Equalizer]
    NumPoints=28
    PointList=3,0, 48,0, 48,1, 226,1, 226,0, 272,0, ,275,3, 275,29, 273,31, 273,84, 275,86, 275,110, 272,113, 265,113, 265,116, 226,116, 226,113, 49,113, 49,116, 10,116, 10,113, 3,113, 0,110, 0,86, 2,84, 2,31, 0,29, 0,3,

    //[Equalizer] (sin las esquinas redondeadas/without round corners)
    NumPoints=24
    PointList=0,0, 48,0, 48,2, 226,2, 226,0, 275,0, 275,29, 273,29, 273,86, 275,86, 275,113, 265,113, 265,116, 226,116, 226,113, 49,113, 49,116, 10,116, 10,113, 0,113, 0,86, 2,86, 2,29, 0,29

    [WindowShade]
    Numpoints=4,4,4,4,4
    PointList=0,0,0,14,79,14,79,0,79,1,118,1,118,13,79,13,118,0,125,0,125,14,118,14,125,1,157,1,157,13,125,13,157,0,275,0,275,14,157,14
    """

private let asciiArt = """
       //////Bag End's Gardener\\\\\\\\\\\\\\
      //-----property of Anika_C-----\\\\
      |This file, like the arrangement|
      |belong to me.                  |
      \\\\  property New Line Cinema.  //
       \\\\\\\\\\\\\\\\///////////////
    """

private func region(_ text: String) -> SkinRegion { RegionParser.parse(text: text) }

private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    }
    return bytes[3]
}

struct RegionParserTests {
    @Test func iniLowercasesSectionsAndKeysAndStripsQuotes() {
        let ini = IniParser.parse("[Normal]\r\nNumPoints = 4\r\nPointList=\"0,0 1,0 1,1 0,1\"\r\n")
        #expect(ini == ["normal": ["numpoints": "4", "pointlist": "0,0 1,0 1,1 0,1"]])
    }

    @Test func iniIgnoresCommentsAndOrphanProperties() {
        let ini = IniParser.parse("NumPoints=4\n; a=b\n[A]\nx=1\n;y=2\nz=b=c\n[A]\nw=3\n")
        #expect(ini == ["a": ["w": "3"]])
        let z = IniParser.parse("[A]\nz=b=c\n")
        #expect(z["a"]?["z"] == "b")
        // Webamp quirk kept on purpose: `//[Equalizer]` is not a section, so the Sony sample's
        // Equalizer ends up with the 24-point variant.
        let sonyIni = IniParser.parse(sony)
        #expect(sonyIni["equalizer"]?["numpoints"] == "24")
    }

    @Test func regionPairsPointsSeparatedBySpacesOrCommas() {
        let pikaRegion = region(pika)
        #expect(pikaRegion.normal?.count == 1)
        #expect(pikaRegion.normal?[0].count == 16)
        #expect(pikaRegion.normal?[0].first == SkinRegion.Point(x: 4, y: 0))
        #expect(pikaRegion.normal?[0].last == SkinRegion.Point(x: 2, y: 1))
        let sonyRegion = region(sony)
        #expect(sonyRegion.normal?.count == 1)
        #expect(sonyRegion.normal?[0].count == 28)
    }

    @Test func regionSplitsMultiplePolygons() {
        let sonyRegion = region(sony)
        #expect(sonyRegion.windowShade?.count == 5)
        #expect(sonyRegion.windowShade?.allSatisfy { $0.count == 4 } == true)
        let none = region("[WindowShade]\nNumPoints=4\nPointList=0,0 1,0 1,1 0,1\n")
        #expect(none.equalizer == nil)
        #expect(none.normal == nil)
    }

    @Test func regionSkipsPolygonsWithFewerThanThreePoints() {
        let parsed = region("[Normal]\nNumPoints=2,3\nPointList=0,0 1,1 2,2 3,3 4,4\n")
        #expect(parsed.normal == [[.init(x: 2, y: 2), .init(x: 3, y: 3), .init(x: 4, y: 4)]])
    }

    @Test func regionTruncatesWhenPointsRunOut() {
        let six = region("[Normal]\nNumPoints=4,4\nPointList=0,0 1,0 2,0 3,0 4,0 5,0\n")
        #expect(six.normal?.map(\.count) == [4, 2])
        let four = region("[Normal]\nNumPoints=4,4\nPointList=0,0 1,0 2,0 3,0\n")
        #expect(four.normal?.map(\.count) == [4])
        let nan = region("[Normal]\nNumPoints=x,4\nPointList=0,0 1,0 2,0 3,0\n")
        #expect(nan.normal?.map(\.count) == [4])
    }

    @Test func regionDropsADanglingCoordinateAndNonNumbers() {
        #expect(region("[Normal]\nNumPoints=3\nPointList=0,0 1,0 1,1 7\n").normal?[0].count == 3)
        let letters = region("[Normal]\nNumPoints=3\nPointList=0,0 1,0 a,b 1,1\n")
        #expect(letters.normal?[0] == [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1)])
        let fraction = region("[Normal]\nNumPoints=3\nPointList=1.5,2 0,0 1,1\n")
        #expect(fraction.normal?[0].first == SkinRegion.Point(x: 1, y: 2))
    }

    @Test func regionWithoutUsableSectionsIsEmpty() {
        #expect(region(asciiArt).isEmpty)
        #expect(region("; just a comment\n; another\n").isEmpty)
        #expect(region("[Normal]\nNumPoints=4\n").isEmpty)
        #expect(region("[Normal]\nNumPoints=0\nPointList=0,0 1,1\n") == .empty)
    }

    @Test func regionExposesTheFourWebampSections() throws {
        let block = "NumPoints=3\nPointList=0,0 1,0 1,1\n"
        let all = region("[Normal]\n\(block)[WindowShade]\n\(block)[Equalizer]\n\(block)[EqualizerWS]\n\(block)[Playlist]\n\(block)")
        #expect(all.normal != nil && all.windowShade != nil && all.equalizer != nil && all.equalizerShade != nil)
        #expect(all.sections["playlist"] != nil)
        let only = try skin(regionText: "[Playlist]\n\(block)", key: "region.txt")
        #expect(!only.region.isEmpty)
        #expect(only.region.normal == nil)
    }

    @Test func regionPathAndMaskFollowThePolygon() throws {
        let a: SkinRegion.Polygon = [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 4), .init(x: 0, y: 4)]
        let b: SkinRegion.Polygon = [.init(x: 10, y: 10), .init(x: 12, y: 10), .init(x: 12, y: 12), .init(x: 10, y: 12)]
        let path = SkinRegion.path([a, b], scale: 2)
        #expect(path.contains(CGPoint(x: 2, y: 2), using: .winding))
        #expect(!path.contains(CGPoint(x: 12, y: 2), using: .winding))
        #expect(path.contains(CGPoint(x: 21, y: 21), using: .winding))
        #expect(path.boundingBox == CGRect(x: 0, y: 0, width: 24, height: 24))
        let mask = try #require(SkinRegion.maskImage([a, b], size: CGSize(width: 20, height: 20), scale: 2))
        #expect(mask.width == 40 && mask.height == 40)
        #expect(alpha(mask, x: 1, y: 1) == 255)
        #expect(alpha(mask, x: 16, y: 2) == 0)
        #expect(alpha(mask, x: 21, y: 21) == 255)
        #expect(alpha(mask, x: 39, y: 39) == 0)
    }

    @Test func parserAttachesRegionToSkin() throws {
        // The synthetic archive only has main.bmp, so other sheets warn; the region must add nothing.
        let without = try skin(regionText: nil, key: "region.txt")
        #expect(without.region == .empty)
        let withPika = try skin(regionText: pika, key: "REGION.TXT")
        #expect(withPika.region.normal?.count == 1)
        #expect(withPika.warnings == without.warnings)
        let withArt = try skin(regionText: asciiArt, key: "region.txt")
        #expect(withArt.region.isEmpty)
        #expect(withArt.warnings == without.warnings)
        #expect(withArt.fallbacks == without.fallbacks)
    }

    private func skin(regionText: String?, key: String) throws -> Skin {
        var files = ["main.bmp": TestBitmaps.bmp(width: 275, height: 116, fill: RGBColor(red: 1, green: 2, blue: 3))]
        if let regionText { files[key] = Data(regionText.utf8) }
        return try SkinParser.parse(archive: SkinArchive(files: files))
    }
}
