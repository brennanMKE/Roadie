import Foundation
import Testing
@testable import SpikeKit

@Suite struct ResultsSheetTests {
    @Test func markdownHasOneRowPerCheckAndOneColumnPerEngine() {
        let lines = ResultsSheet().markdown().split(separator: "\n").map(String.init)
        #expect(lines.count == 2 + Check.allCases.count)
        let header = lines[0].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(header == ["Check"] + EngineKind.allCases.map(\.title))
        for line in lines.dropFirst(2) {
            #expect(line.components(separatedBy: "untested").count - 1 == EngineKind.allCases.count)
        }
    }

    @Test func settingOneCellChangesExactlyOneCell() {
        let before = ResultsSheet()
        var after = before
        after[.b, .twoInSync] = .yes
        var changed = 0
        for kind in EngineKind.allCases {
            for check in Check.allCases where before[kind, check] != after[kind, check] { changed += 1 }
        }
        #expect(changed == 1)
        #expect(after.markdown().contains("| Two HomePods in sync |"))
        #expect(after.markdown() != before.markdown())
    }

    /// The doc's table must be the sheet's output so the two never drift.
    @Test func docTableMatchesSheet() throws {
        // .../Spikes/AirPlaySpike/SpikeKit/Tests/SpikeKitTests/ResultsSheetTests.swift
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let doc = root.appendingPathComponent("docs/airplay-spike-results.md")
        guard let text = try? String(contentsOf: doc, encoding: .utf8) else {
            Issue.record("docs/airplay-spike-results.md not found at \(doc.path)")
            return
        }
        #expect(text.contains(ResultsSheet().markdown()))
    }
}
