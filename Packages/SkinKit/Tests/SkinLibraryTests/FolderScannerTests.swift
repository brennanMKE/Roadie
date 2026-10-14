import Foundation
import Testing

@testable import SkinLibrary

@Suite struct FolderScannerTests {
    private func put(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func listsWszRecursivelySkippingHiddenAndOtherExtensions() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try put(folder.appending(path: "a.wsz"), "12345")
        try put(folder.appending(path: "sub/b.WSZ"))
        try put(folder.appending(path: ".hidden.wsz"))
        try put(folder.appending(path: "c.zip"))
        try put(folder.appending(path: "d.txt"))
        let stamps = try FolderScanner.list(folder: folder)
        #expect(stamps.map(\.path) == ["a.wsz", "sub/b.WSZ"])
        #expect(stamps[0].size == 5)
        #expect(stamps[0].mtime > 0)
        #expect(try FolderScanner.list(folder: folder, extensions: ["wsz", "zip"]).map(\.path) == ["a.wsz", "c.zip", "sub/b.WSZ"])
    }

    @Test func relativePathsIgnoreTheFolderPrefixAndSymlinkedRoot() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try put(folder.appending(path: "x/one.wsz"))
        let link = dir.appending("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(try FolderScanner.list(folder: link).map(\.path) == ["x/one.wsz"])
    }

    @Test func missingFolderThrowsFolderUnreadable() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        #expect(throws: SkinLibraryError.self) { try FolderScanner.list(folder: dir.appending("nope")) }
    }

    @Test func doesNotFollowDirectorySymlinks() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.skinsFolder()
        try put(folder.appending(path: "a.wsz"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "loop"), withDestinationURL: dir.url)
        #expect(try FolderScanner.list(folder: folder).map(\.path) == ["a.wsz"])
    }
}
