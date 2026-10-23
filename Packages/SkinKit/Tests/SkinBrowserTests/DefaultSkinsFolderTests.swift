import Foundation
import Testing

@testable import SkinBrowser

struct DefaultSkinsFolderTests {
    private func makeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &flag) && flag.boolValue
    }

    @Test func urlIsRoadieSkinsUnderHome() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(DefaultSkinsFolder.url(home: home).path(percentEncoded: false).hasPrefix("/Users/someone/Roadie/Skins"))
    }

    @Test func ensureCreatesTheFolderAndIntermediates() throws {
        let home = try makeTemp()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = DefaultSkinsFolder.url(home: home)
        #expect(!isDirectory(home.appending(path: "Roadie")))
        try DefaultSkinsFolder.ensure(at: url)
        #expect(isDirectory(home.appending(path: "Roadie")))
        #expect(isDirectory(url))
    }

    @Test func ensureKeepsAnExistingFolder() throws {
        let home = try makeTemp()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = DefaultSkinsFolder.url(home: home)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appending(path: "keep.txt")
        try Data("x".utf8).write(to: file)
        try DefaultSkinsFolder.ensure(at: url)
        #expect(try Data(contentsOf: file) == Data("x".utf8))
    }

    @Test func ensureThrowsWhenAFileIsInTheWay() throws {
        let home = try makeTemp()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("x".utf8).write(to: home.appending(path: "Roadie"))
        #expect(throws: (any Error).self) { try DefaultSkinsFolder.ensure(at: DefaultSkinsFolder.url(home: home)) }
        let blocked = home.appending(path: "blocked", directoryHint: .isDirectory)
        try Data("x".utf8).write(to: home.appending(path: "blocked"))
        #expect(throws: (any Error).self) { try DefaultSkinsFolder.ensure(at: blocked) }
    }

    @Test func hasNoSkinsIsTrueForEmptyAndFalseWithAWsz() throws {
        let folder = try makeTemp()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(DefaultSkinsFolder.hasNoSkins(folder))
        let sub = folder.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("PK".utf8).write(to: sub.appending(path: "a.wsz"))
        #expect(!DefaultSkinsFolder.hasNoSkins(folder))
        #expect(DefaultSkinsFolder.hasNoSkins(folder.appending(path: "missing", directoryHint: .isDirectory)))
    }
}
