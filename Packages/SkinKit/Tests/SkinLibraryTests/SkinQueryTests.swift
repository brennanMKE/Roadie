import Foundation
import Testing

@testable import SkinLibrary

/// The browser's query methods on the real store (small seeds; the 100k budget test is `SkinSearchBudgetTests`).
@Suite struct SkinQueryTests {
    private func seed(_ store: SkinIndexStore, _ rows: [(name: String, readme: String?, status: SkinStatus)]) async throws {
        let batch = rows.enumerated().map { index, row in
            parsedOutcome("d/\(index).wsz", hash: "h\(index)", name: row.name, readme: row.readme, status: row.status)
        }
        _ = try await store.apply(batch)
    }

    @Test func queryCombinesTextAndStatuses() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        var rows: [(name: String, readme: String?, status: SkinStatus)] = []
        for n in 0..<30 {
            let status: SkinStatus = n % 3 == 0 ? .partial : (n % 3 == 1 ? .ok : .failed)
            rows.append((n % 2 == 0 ? "Dragon \(n)" : "other \(n)", n % 5 == 0 ? "a dragon readme" : nil, status))
        }
        try await seed(store, rows)

        let partial = SkinQuery(text: "drag", statuses: [.partial])
        let found = try await store.skins(matching: partial)
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.status == .partial })
        #expect(found.allSatisfy { $0.name.lowercased().hasPrefix("drag") || ($0.readme ?? "").contains("dragon") })
        let all = try await store.skins(matching: SkinQuery(text: "drag"))
        #expect(all.count > found.count)
        #expect(try await store.count(matching: partial) == found.count)
        #expect(try await store.count(matching: SkinQuery(text: "drag")) == all.count)
        #expect(try await store.count(matching: SkinQuery()) == 30)
        #expect(try await store.skins(matching: SkinQuery(statuses: [])).isEmpty)
        #expect(try await store.count(matching: SkinQuery(statuses: [])) == 0)
    }

    @Test func queryPagesInStableOrder() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        try await seed(store, (0..<450).map { (name: "Skin \($0 % 100)", readme: nil, status: .ok) })
        var ids: [Int64] = []
        for offset in [0, 200, 400] {
            ids += try await store.skins(matching: SkinQuery(limit: 200, offset: offset)).map(\.id)
        }
        #expect(ids.count == 450)
        #expect(Set(ids).count == 450)
        #expect(ids == (try await store.skins(limit: 450)).map(\.id))
    }

    @Test func queryWithTextRanksThenNames() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        let filler = Array(repeating: "lorem ipsum dolor sit amet", count: 40).joined(separator: " ")
        try await seed(store, [("aaa plain", filler + " dragon", .ok), ("dragon", nil, .ok)])
        let found = try await store.skins(matching: SkinQuery(text: "dragon"))
        #expect(found.map(\.name) == ["dragon", "aaa plain"])
    }

    @Test func queryToleratesPunctuation() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        try await seed(store, [("a b", nil, .ok)])
        for text in ["\"a:b", "\"\"", "**", "NEAR(", "a\"", "(a OR", "-x"] {
            _ = try await store.skins(matching: SkinQuery(text: text))
            _ = try await store.count(matching: SkinQuery(text: text))
        }
    }

    @Test func broadMatchesAreListedByNameAndStayPaged() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        let rows = (0..<(SkinIndexStore.broadMatchThreshold + 300)).map {
            (name: String(format: "skin %05d", $0), readme: nil as String?, status: SkinStatus.ok)
        }
        for chunk in stride(from: 0, to: rows.count, by: 1000) {
            let slice = rows[chunk..<min(chunk + 1000, rows.count)]
            _ = try await store.apply(slice.enumerated().map { index, row in
                parsedOutcome("d/\(chunk + index).wsz", hash: "h\(chunk + index)", name: row.name)
            })
        }
        let page = try await store.skins(matching: SkinQuery(text: "sk", limit: 50, offset: 100))
        #expect(page.map(\.name) == (100..<150).map { String(format: "skin %05d", $0) })
        #expect(try await store.count(matching: SkinQuery(text: "sk")) == rows.count)
    }

    @Test func neighborWrapsAndSkipsFilteredStatuses() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        try await seed(store, [("beta", nil, .ok), ("Alpha", nil, .partial), ("Gamma", nil, .ok), ("Delta", nil, .failed)])
        let loadable: Set<SkinStatus> = [.ok, .partial]
        let byName = try await store.skins(limit: 10)
        #expect(byName.map(\.name) == ["Alpha", "beta", "Delta", "Gamma"])
        let alpha = byName[0], beta = byName[1], delta = byName[2], gamma = byName[3]
        #expect(try await store.neighbor(of: alpha.id, direction: .next, statuses: loadable)?.id == beta.id)
        #expect(try await store.neighbor(of: beta.id, direction: .next, statuses: loadable)?.id == gamma.id)
        #expect(try await store.neighbor(of: gamma.id, direction: .next, statuses: loadable)?.id == alpha.id)
        #expect(try await store.neighbor(of: alpha.id, direction: .previous, statuses: loadable)?.id == gamma.id)
        #expect(try await store.neighbor(of: gamma.id, direction: .previous, statuses: loadable)?.id == beta.id)
        // A failed current skin steps over to the next loadable one.
        #expect(try await store.neighbor(of: delta.id, direction: .next, statuses: loadable)?.id == gamma.id)
        #expect(try await store.neighbor(of: 9999, direction: .next, statuses: loadable)?.id == alpha.id)
        #expect(try await store.neighbor(of: 9999, direction: .previous, statuses: loadable)?.id == gamma.id)
        #expect(try await store.neighbor(of: alpha.id, direction: .next, statuses: []) == nil)
        #expect(try await store.neighbor(of: alpha.id, direction: .next, statuses: [.failed])?.id == delta.id)
    }

    @Test func equalNamesStepInIDOrder() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        try await seed(store, [("skin", nil, .ok), ("Skin", nil, .ok), ("SKIN", nil, .ok)])
        var current = try await store.skins(limit: 1)[0].id
        var seen: [Int64] = []
        for _ in 0..<4 {
            current = try #require(try await store.neighbor(of: current, direction: .next, statuses: [.ok])).id
            seen.append(current)
        }
        #expect(seen == [2, 3, 1, 2])
    }

    @Test func skinAtPathFindsTheRecordForAnyOfItsFiles() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        _ = try await store.apply([parsedOutcome("a/one.wsz", hash: "same", name: "one"), linkedOutcome("b/two.wsz", hash: "same")])
        let first = try await store.skin(atPath: "a/one.wsz")
        let second = try await store.skin(atPath: "b/two.wsz")
        #expect(first != nil && first?.id == second?.id)
        #expect(first?.fileCount == 2)
        #expect(try await store.skin(atPath: "nope.wsz") == nil)
    }

    @Test func randomSkinHonoursTheStatusSet() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()
        try await seed(store, (0..<20).map { (name: "s\($0)", readme: nil, status: $0 % 4 == 0 ? .partial : .ok) })
        for _ in 0..<100 {
            #expect(try await store.randomSkin(statuses: [.partial])?.status == .partial)
        }
        #expect(try await store.randomSkin(statuses: []) == nil)
        #expect(try await store.randomSkin(statuses: [.failed]) == nil)
    }
}
