import Foundation
import Testing

@testable import SkinLibrary

func parsedOutcome(
    _ path: String, hash: String, name: String? = nil, readme: String? = nil, status: SkinStatus = .ok,
    warnings: [String] = [], version: Int = 1, size: Int64 = 10, mtime: Double = 1
) -> IngestOutcome {
    .parsed(
        stamp: FileStamp(path: path, size: size, mtime: mtime), hash: hash,
        name: name ?? URL(filePath: path).deletingPathExtension().lastPathComponent, readme: readme, status: status,
        warnings: warnings, parserVersion: version)
}

func linkedOutcome(_ path: String, hash: String, size: Int64 = 10, mtime: Double = 1) -> IngestOutcome {
    .linked(stamp: FileStamp(path: path, size: size, mtime: mtime), hash: hash)
}

@Suite struct SkinIndexStoreTests {
    @Test func migrateCreatesSchemaAtVersion1AndIsIdempotent() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.appending("db/index.sqlite")
        let store = try await SkinIndexStore.open(at: url)
        #expect(try await store.strings("PRAGMA user_version") == ["1"])
        let tables = try await store.strings("SELECT name FROM sqlite_master WHERE type = 'table'")
        for name in ["skins", "files", "meta", "skins_fts"] { #expect(tables.contains(name)) }
        _ = try await store.apply([parsedOutcome("a.wsz", hash: "h1")])
        let again = try await SkinIndexStore.open(at: url)
        #expect(try await again.strings("PRAGMA user_version") == ["1"])
        #expect(try await again.counts().skins == 1)
    }

    @Test func newerSchemaThrowsIncompatible() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.appending("index.sqlite")
        let store = try await SkinIndexStore.open(at: url)
        await store.setUserVersion(99)
        do {
            _ = try await SkinIndexStore.open(at: url)
            Issue.record("a newer schema should be refused")
        } catch SkinLibraryError.incompatibleDatabase(let found, let supported) {
            #expect(found == 99)
            #expect(supported == SkinIndexStore.schemaVersion)
        }
    }

    @Test func applyInsertsSkinAndFile() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        let counts = try await store.apply([
            parsedOutcome("sub/Cool.wsz", hash: "h1", readme: "hello", status: .partial, warnings: ["w1", "w2"], size: 42)
        ])
        #expect(counts == AppliedCounts(added: 1, updated: 0, linked: 0))
        let record = try #require(try await store.skin(hash: "h1"))
        #expect(record.name == "Cool")
        #expect(record.readme == "hello")
        #expect(record.status == .partial)
        #expect(record.warnings == ["w1", "w2"])
        #expect(record.size == 42)
        #expect(record.fileCount == 1)
        #expect(record.primaryPath == "sub/Cool.wsz")
        #expect(try await store.files(forSkin: record.id) == [FileStamp(path: "sub/Cool.wsz", size: 42, mtime: 1)])
    }

    @Test func applyLinksSecondFileToTheSameHash() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        // Given reversed: the lexicographically first path still names the skin.
        let counts = try await store.apply([
            linkedOutcome("z.wsz", hash: "h1"), parsedOutcome("a.wsz", hash: "h1", name: "a"),
        ])
        #expect(counts == AppliedCounts(added: 1, updated: 0, linked: 1))
        let all = try await store.counts()
        #expect(all.skins == 1 && all.files == 2)
        let record = try #require(try await store.skin(hash: "h1"))
        #expect(record.name == "a")
        #expect(record.fileCount == 2)
        #expect(record.primaryPath == "a.wsz")
    }

    @Test func applyWithNewParserVersionUpdatesInPlace() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        _ = try await store.apply([parsedOutcome("a.wsz", hash: "h1", readme: "old", status: .ok)])
        let before = try #require(try await store.skin(hash: "h1"))
        let counts = try await store.apply([
            parsedOutcome("a.wsz", hash: "h1", name: "renamed", readme: "new", status: .partial, warnings: ["x"], version: 2)
        ])
        #expect(counts == AppliedCounts(added: 0, updated: 1, linked: 0))
        let after = try #require(try await store.skin(hash: "h1"))
        #expect(after.id == before.id)
        #expect(after.name == "a")
        #expect(after.status == .partial)
        #expect(after.readme == "new")
        #expect(after.warnings == ["x"])
        let stamps = try await store.fileStamps()
        #expect(stamps["a.wsz"]?.parserVersion == 2)
    }

    @Test func removeFilesLeavesSkinUntilPruned() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        _ = try await store.apply([parsedOutcome("a.wsz", hash: "h1", readme: "uniqueword")])
        #expect(try await store.removeFiles(["a.wsz"]) == 1)
        #expect(try await store.counts().skins == 1)
        #expect(try await store.counts().files == 0)
        #expect(try await store.search("uniqueword").count == 1)
        #expect(try await store.pruneOrphans() == 1)
        #expect(try await store.counts().skins == 0)
        #expect(try await store.search("uniqueword").isEmpty)
    }

    @Test func skinIDsForHashesHandlesMoreThan500() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        let outcomes = (0..<1200).map { parsedOutcome("s\($0).wsz", hash: "h\($0)") }
        _ = try await store.apply(outcomes)
        let hashes = (0..<1500).map { "h\($0)" }
        let ids = try await store.skinIDs(forHashes: hashes)
        #expect(ids.count == 1200)
        #expect(ids["h1199"] != nil && ids["h1200"] == nil)
        // Only hashes at or above the parser version count as known.
        #expect(try await store.knownSkinIDs(forHashes: hashes, parserVersion: 2).isEmpty)
    }

    @Test func searchMatchesNameAndReadmeByPrefixCaseInsensitively() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        _ = try await store.apply([
            parsedOutcome("a.wsz", hash: "h1", name: "Asian Dragon"),
            parsedOutcome("b.wsz", hash: "h2", name: "Plain", readme: "Made for the Trinity project"),
            parsedOutcome("c.wsz", hash: "h3", name: "Old_Mac-OS"),
        ])
        #expect(try await store.search("drag").map(\.hash) == ["h1"])
        #expect(try await store.search("DRAGON").map(\.hash) == ["h1"])
        #expect(try await store.search("trinity").map(\.hash) == ["h2"])
        #expect(try await store.search("Dr").map(\.hash) == ["h1"])
        #expect(try await store.search("mac os").map(\.hash) == ["h3"])
        #expect(try await store.search("nothing-here").isEmpty)
    }

    @Test func searchToleratesPunctuationAndQuotes() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        _ = try await store.apply([parsedOutcome("a.wsz", hash: "h1", name: "a b")])
        for text in ["\"a:b", "\"", "*", "NEAR(", "a AND", "(", "", "   ", "a\"b", "-", "x OR y", "name:"] {
            _ = try await store.search(text)
        }
        #expect(try await store.search("\"").isEmpty)
    }

    @Test func searchFiltersByStatus() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        _ = try await store.apply([
            parsedOutcome("a.wsz", hash: "h1", name: "dragon one", status: .ok),
            parsedOutcome("b.wsz", hash: "h2", name: "dragon two", status: .partial),
        ])
        #expect(try await store.search("dragon").count == 2)
        #expect(try await store.search("dragon", status: .partial).map(\.hash) == ["h2"])
        #expect(try await store.search("dragon", status: .failed).isEmpty)
    }

    @Test func skinsPageAndOrderByName() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        let names = ["banana", "Apple", "cherry", "apricot", "Blueberry"]
        _ = try await store.apply(names.enumerated().map { parsedOutcome("\($0.offset).wsz", hash: "h\($0.offset)", name: $0.element) })
        #expect(try await store.skins().map(\.name) == ["Apple", "apricot", "banana", "Blueberry", "cherry"])
        #expect(try await store.skins(limit: 2, offset: 1).map(\.name) == ["apricot", "banana"])
        #expect(try await store.skins(limit: 2, offset: 4).map(\.name) == ["cherry"])
    }

    @Test func randomSkinReturnsNilOnEmptyAndAMatchingStatus() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        #expect(try await store.randomSkin() == nil)
        _ = try await store.apply([
            parsedOutcome("a.wsz", hash: "h1", status: .ok), parsedOutcome("b.wsz", hash: "h2", status: .failed),
        ])
        #expect(try await store.randomSkin() != nil)
        for _ in 0..<10 { #expect(try await store.randomSkin(status: .failed)?.hash == "h2") }
        #expect(try await store.randomSkin(status: .partial) == nil)
    }

    @Test func countsByStatus() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        _ = try await store.apply([
            parsedOutcome("a.wsz", hash: "h1", status: .ok), parsedOutcome("b.wsz", hash: "h2", status: .ok),
            parsedOutcome("c.wsz", hash: "h3", status: .partial), linkedOutcome("d.wsz", hash: "h1"),
        ])
        let counts = try await store.counts()
        #expect(counts.files == 4)
        #expect(counts.skins == 3)
        #expect(counts.byStatus == [.ok: 2, .partial: 1, .failed: 0])
    }

    @Test func resetEmptiesEverything() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        _ = try await store.apply([parsedOutcome("a.wsz", hash: "h1", name: "findme")])
        try await store.setMeta("folder", "/x")
        try await store.reset()
        #expect(try await store.counts().skins == 0)
        #expect(try await store.counts().files == 0)
        #expect(try await store.meta("folder") == nil)
        #expect(try await store.search("findme").isEmpty)
        #expect(try await store.strings("PRAGMA user_version") == ["1"])
        _ = try await store.apply([parsedOutcome("a.wsz", hash: "h1", name: "findme")])
        #expect(try await store.search("findme").count == 1)
    }

    @Test func metaRoundTrips() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        #expect(try await store.meta("k") == nil)
        try await store.setMeta("k", "v1")
        try await store.setMeta("k", "v2")
        #expect(try await store.meta("k") == "v2")
    }
}
