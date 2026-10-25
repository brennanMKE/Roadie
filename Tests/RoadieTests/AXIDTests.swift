import AudioCore
import XCTest

@testable import Roadie

/// The accessibility identifiers of the skinned windows and the state probe (#0199). The models are built with
/// `PlayerModel()`: #0194's test-mode configuration hasn't landed yet.
@MainActor
final class AXIDTests: XCTestCase {
    func testIdentifiersAreUnique() {
        let duplicates = Dictionary(grouping: AXID.all, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(Set(AXID.all).count, AXID.all.count, "duplicates: \(duplicates)")
    }

    /// Lower-case dotted segments; a segment after the first may be camel case (`pl.runningTime`, design §3.2).
    func testIdentifiersUseTheDottedScheme() throws {
        let regex = try NSRegularExpression(pattern: "^[a-z]+(\\.[a-z0-9][a-zA-Z0-9]*)+$")
        for id in AXID.all + AXID.EQ.bands + [AXID.PL.row(12), AXID.Jump.row(3)] {
            let range = NSRange(id.startIndex..., in: id)
            XCTAssertNotNil(regex.firstMatch(in: id, range: range), id)
        }
    }

    /// The text a playlist row exposes (label and value), read from the model. Whether the live SwiftUI tree carries
    /// it is checked by #0200's XCUITest smoke test: a hosted unit test has no accessibility client, so the hosting
    /// views never materialise their elements for an in-process walk.
    func testPlaylistRowsCarryTheirAccessibilityText() {
        let model = Self.modelWithThreeTracks(current: 1)
        let rows = model.playlist.rows
        XCTAssertEqual(rows.map(\.index), [0, 1, 2])
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(AXID.PL.row(row.index), "pl.row.\(i)")
            XCTAssertEqual(row.number + row.name, "\(i + 1). Tone Artist - Tone \(["A", "B", "C"][i])")
            XCTAssertEqual(row.accessibilityValue, "marker= duration=2:30 current=\(i == 1)")
        }
    }

    func testProbeReportsTheQueue() throws {
        let model = Self.modelWithThreeTracks(current: 1)
        let json = model.testProbe().json
        let probe = try JSONDecoder().decode(TestProbe.self, from: Data(json.utf8))
        XCTAssertEqual(
            probe,
            TestProbe(
                output: "thisMac", feed: "local", state: "stopped", currentIndex: 1,
                queue: [
                    .init(title: "Tone Artist - Tone A", marker: "", current: false),
                    .init(title: "Tone Artist - Tone B", marker: "", current: true),
                    .init(title: "Tone Artist - Tone C", marker: "", current: false),
                ],
                notice: nil, lastExternalOpen: nil, tokenStore: "keychain", maRequests: []))
        XCTAssertTrue(json.contains("\"notice\":null"), json)
    }

    // MARK: Helpers

    /// Three 2:30 tracks restored stopped (nothing plays) with `current` selected.
    static func modelWithThreeTracks(current: Int) -> PlayerModel {
        let model = PlayerModel()
        model.player.clearQueue()
        let tracks = ["A", "B", "C"].map {
            Track(
                title: "Tone \($0)", artist: "Tone Artist", duration: 150,
                source: .file(URL(fileURLWithPath: "/nonexistent/Tone \($0).mp3")))
        }
        model.player.restoreQueue(tracks, currentIndex: current, repeatMode: .off, isShuffled: false)
        return model
    }
}
