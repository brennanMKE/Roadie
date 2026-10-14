import Foundation
import Testing
@testable import SkinKit

struct SkinArchiveLimitsTests {
    @Test func entryCapDropsLargeEntry() throws {
        let url = try ZipFixtures.zip([("main.bmp", Data(repeating: 1, count: 50)), ("viscolor.txt", Data(repeating: 2, count: 5))])
        let archive = try SkinArchive(url: url, limits: SkinArchive.Limits(maxEntryBytes: 10))
        #expect(Set(archive.files.keys) == ["viscolor.txt"])
    }

    @Test func extensionAllowListDropsExecutables() throws {
        let url = try ZipFixtures.zip([
            ("main.bmp", Data(repeating: 1, count: 5)), ("readme.exe", Data(repeating: 2, count: 5)), ("x.dll", Data(repeating: 3, count: 5)),
        ])
        let archive = try SkinArchive(url: url)
        #expect(archive.files["main.bmp"] != nil)
        #expect(archive.files["readme.exe"] == nil && archive.files["x.dll"] == nil)
    }

    @Test func totalCapStopsReading() throws {
        let url = try ZipFixtures.zip((0..<10).map { ("f\($0).txt", Data(repeating: UInt8($0), count: 30)) })
        let archive = try SkinArchive(url: url, limits: SkinArchive.Limits(maxTotalBytes: 100))
        #expect(archive.files.count <= 3 && !archive.files.isEmpty)
    }

    @Test func defaultsAreUnchangedForCallers() throws {
        let modern = try ZipFixtures.zip([("skin.xml", Data("<skin/>".utf8))])
        #expect(try SkinArchive(url: modern).files["skin.xml"] != nil)
        #expect(throws: SkinError.self) { try SkinParser.parse(url: modern) }
        let cursor = try ZipFixtures.zip([("normal.cur", Data(repeating: 0, count: 8))])
        #expect(try SkinArchive(url: cursor).files["normal.cur"] != nil)
    }
}
