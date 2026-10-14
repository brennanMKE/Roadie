import Foundation
import Testing

@testable import SkinLibrary

/// The Skins window's 200 ms search budget on 100,000 rows. The assertion is on the median of five runs of the
/// page query plus its count, after one warm-up run, so one scheduling hiccup in a loaded VM cannot fail it.
@Suite struct SkinSearchBudgetTests {
    static let rows = 100_000

    @Test(.timeLimit(.minutes(5)))
    func searchOnHundredThousandRowsStaysUnder200ms() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let store = try await dir.makeStore()

        let adjectives = (0..<200).map { "adj\($0)" }, nouns = (0..<200).map { "noun\($0)" }
        let vocabulary = (0..<500).map { "word\($0)" }
        var state: UInt64 = 987_654_321
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % bound
        }
        let seedStart = ContinuousClock.now
        for start in stride(from: 0, to: Self.rows, by: 1000) {
            let batch = (start..<start + 1000).map { n -> IngestOutcome in
                let readme = (0..<40).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: " ")
                // "rare" appears in about 100 rows; "common" in about half; every name starts with "skin".
                var name = "skin \(adjectives[next(200)]) \(nouns[next(200)]) \(n)"
                if n % 1000 == 7 { name += " rare" }
                if n % 2 == 0 { name += " common" }
                let status: SkinStatus = n % 100 == 3 ? .failed : (n % 10 == 5 ? .partial : .ok)
                return parsedOutcome("d\(n / 1000)/\(n).wsz", hash: "h\(n)", name: name, readme: readme, status: status)
            }
            _ = try await store.apply(batch)
        }
        print("SEARCH seed \(Self.rows) rows: \(seedStart.duration(to: .now))")
        #expect(try await store.counts().skins == Self.rows)

        let cases: [(label: String, query: SkinQuery)] = [
            ("rare word", SkinQuery(text: "rare")),
            ("common word", SkinQuery(text: "common")),
            ("two words", SkinQuery(text: "rare adj1")),
            ("two-letter prefix", SkinQuery(text: "sk")),
            ("no match", SkinQuery(text: "zzzzqx")),
            ("rare, partial only", SkinQuery(text: "rare", statuses: [.partial])),
            ("listing at offset 50,000", SkinQuery(limit: 200, offset: 50_000)),
        ]
        for (label, query) in cases {
            _ = try await store.skins(matching: query)
            _ = try await store.count(matching: query)
            var samples: [Duration] = []
            var hits = 0
            for _ in 0..<5 {
                let start = ContinuousClock.now
                hits = try await store.skins(matching: query).count
                _ = try await store.count(matching: query)
                samples.append(start.duration(to: .now))
            }
            let median = samples.sorted()[2]
            print("SEARCH \(label): median \(median) (\(hits) rows in page), samples \(samples.sorted())")
            #expect(median < .milliseconds(200), "\(label) took \(median)")
        }
    }
}
