import Foundation
import MusicBackendKit
import PlayerKitTestFixtures
import Testing
@testable import FolderBackendKit

/// The fixture music folder (#0195): real tagged MP3/AAC/ALAC/FLAC/WAV files laid out as Artist/Album/Track.
@Suite struct FolderBackendFixtureLibraryTests {
    /// `scripts/make-test-library.sh`, found from this file's path; nil when the tests run without the repo.
    static let script: URL? = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        let script = url.appending(path: "scripts/make-test-library.sh")
        return FileManager.default.isExecutableFile(atPath: script.path) ? script : nil
    }()

    /// Every regular file under `root`, relative and sorted.
    static func listing(_ root: URL) -> [String] {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: [String] = []
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            paths.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path)
        }
        return paths.sorted()
    }

    @Test func fixtureLibraryIndexesArtistsAlbumsAndDiscs() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try AudioFixtures.makeLibrary(at: root)
        let index = try await FolderIndexer().build(root: root, previous: nil)

        #expect(index.artists.map(\.name) == expected.artists)
        #expect(index.albums.count == expected.albums.count)
        #expect(index.tracks.count == 7)
        #expect(index.skipped.isEmpty, "\(index.skipped.map(\.relativePath))")
        for album in expected.albums {
            let found = try #require(
                index.albums.first { $0.title == album.title && $0.artistName == album.artist }, "\(album.title)")
            let tracks = index.tracks.map(\.library).filter { $0.albumID == found.id }
            #expect(tracks.map(\.title) == album.tracks, "\(album.title)")
            #expect(tracks.map(\.discNumber) == album.discs, "\(album.title)")
        }
        let single = try #require(index.albums.first { $0.title == "Singles" })
        #expect(single.artistID == artistID("Other Artist"))
        #expect(single.id == albumID("Other Artist"))
    }

    @Test(.enabled(if: FolderBackendFixtureLibraryTests.script != nil, "scripts/make-test-library.sh not found next to the package"))
    func makeLibraryMatchesTheScript() throws {
        let swiftRoot = makeTempDir("fixture-swift")
        let shellRoot = makeTempDir("fixture-shell")
        defer {
            try? FileManager.default.removeItem(at: swiftRoot)
            try? FileManager.default.removeItem(at: shellRoot)
        }
        let expected = try AudioFixtures.makeLibrary(at: swiftRoot)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [try #require(Self.script).path, shellRoot.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let swiftFiles = Self.listing(swiftRoot)
        #expect(swiftFiles == expected.files)
        #expect(Self.listing(shellRoot) == swiftFiles)
        for path in swiftFiles {
            let a = try Data(contentsOf: swiftRoot.appending(path: path))
            let b = try Data(contentsOf: shellRoot.appending(path: path))
            #expect(a == b, "\(path) differs between makeLibrary(at:) and the script")
        }
    }
}
