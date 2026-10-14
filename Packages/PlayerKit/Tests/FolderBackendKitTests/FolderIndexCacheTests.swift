import Foundation
import MusicBackendKit
import Testing
@testable import FolderBackendKit

@Suite struct FolderIndexCacheTests {
    private func makeIndex(_ root: URL) async throws -> FolderIndex {
        try makeLibrary(in: root)
        return try await FolderIndexer().build(root: root, previous: nil)
    }

    @Test func roundTripsThroughJSON() async throws {
        let root = makeTempDir(), cache = makeTempDir("FolderBackendKitTests-cache")
        defer { for url in [root, cache] { try? FileManager.default.removeItem(at: url) } }
        let index = try await makeIndex(root)

        try FolderIndexCache.save(index, in: cache)
        let loaded = try #require(FolderIndexCache.load(for: root, in: cache))
        #expect(loaded == index)

        let file = FolderIndexCache.fileURL(for: root, in: cache)
        #expect(file.lastPathComponent.range(of: #"^index-[0-9a-f]{16}\.json$"#, options: .regularExpression) != nil)
        if root.path.hasPrefix("/var/") {
            let spelled = URL(fileURLWithPath: "/private" + root.path)
            #expect(FolderIndexCache.fileURL(for: spelled, in: cache) == file)
        }
    }

    @Test func rejectsAnotherRootOrVersion() async throws {
        let root = makeTempDir(), other = makeTempDir(), cache = makeTempDir("FolderBackendKitTests-cache")
        defer { for url in [root, other, cache] { try? FileManager.default.removeItem(at: url) } }
        let index = try await makeIndex(root)
        try FolderIndexCache.save(index, in: cache)
        #expect(FolderIndexCache.load(for: other, in: cache) == nil)

        // Another root's index stored under this root's file name is refused and deleted.
        let wrongFile = FolderIndexCache.fileURL(for: other, in: cache)
        try FileManager.default.copyItem(at: FolderIndexCache.fileURL(for: root, in: cache), to: wrongFile)
        #expect(FolderIndexCache.load(for: other, in: cache) == nil)
        #expect(!FileManager.default.fileExists(atPath: wrongFile.path))

        // A hand-edited version.
        let file = FolderIndexCache.fileURL(for: root, in: cache)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["version"] = 0
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(FolderIndexCache.load(for: root, in: cache) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Corrupt bytes.
        try FolderIndexCache.save(index, in: cache)
        try Data("{not json".utf8).write(to: file)
        #expect(FolderIndexCache.load(for: root, in: cache) == nil)
    }

    @Test func removeDeletesOnlyThatRootsFile() async throws {
        let root = makeTempDir(), other = makeTempDir(), cache = makeTempDir("FolderBackendKitTests-cache")
        defer { for url in [root, other, cache] { try? FileManager.default.removeItem(at: url) } }
        let index = try await makeIndex(root)
        try FolderIndexCache.save(index, in: cache)
        try FolderIndexCache.save(FolderIndex.empty(root: other), in: cache)

        FolderIndexCache.remove(for: root, in: cache)
        #expect(FolderIndexCache.load(for: root, in: cache) == nil)
        #expect(FolderIndexCache.load(for: other, in: cache) != nil)
    }
}
