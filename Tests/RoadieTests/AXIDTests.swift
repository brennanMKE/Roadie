import AudioCore
import Foundation
import MusicAssistantKit
import MusicAssistantKitStub
import XCTest

@testable import Roadie

/// The accessibility identifiers of the skinned windows and the state probe (#0199). Every model is built with an
/// isolated test configuration (#0194): a temp data directory and defaults suite, so nothing autosaves to the real
/// queue file or touches the Keychain.
@MainActor
final class AXIDTests: XCTestCase {
    private var suiteNames: [String] = []
    private var folders: [URL] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        suiteNames = []
        folders = []
    }

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
        let model = modelWithThreeTracks(current: 1)
        let rows = model.playlist.rows
        XCTAssertEqual(rows.map(\.index), [0, 1, 2])
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(AXID.PL.row(row.index), "pl.row.\(i)")
            XCTAssertEqual(row.number + row.name, "\(i + 1). Tone Artist - Tone \(["A", "B", "C"][i])")
            XCTAssertEqual(row.accessibilityValue, "marker= duration=2:30 current=\(i == 1)")
        }
    }

    func testProbeReportsTheQueue() throws {
        let model = modelWithThreeTracks(current: 1)
        XCTAssertFalse(model.configuration.isUITest)
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
                notice: nil, lastExternalOpen: nil, tokenStore: "memory", maRequests: [],
                sendspinEnabled: model.sendspinController.isEnabled, firstRunVersion: nil))
        XCTAssertTrue(json.contains("\"notice\":null"), json)
        XCTAssertTrue(json.contains("\"lastExternalOpen\":null"), json)
        XCTAssertTrue(json.contains("\"visualization\":null"), json)
        XCTAssertTrue(json.contains("\"firstRunVersion\":null"), json)
    }

    /// With the scripted Music Assistant (#0197) the probe reports the in-memory token store, the recorded external
    /// open and the server's redacted command summaries, and its JSON never carries the token.
    func testProbeReportsTheScriptedMusicAssistant() async throws {
        let model = PlayerModel(configuration: try testConfiguration(.scripted(scenario: "libraryIdle")))
        try await model.musicAssistant.connect()
        let help = URL(string: "https://roadie.sstools.co/help.html")!
        model.open(external: help)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        // The raw transport log does hold the token, so the probe must not be built from it.
        XCTAssertTrue(server.transports.contains { $0.sent.contains { $0.contains(ScriptedMusicAssistant.token.rawValue) } })

        // The client keeps sending after `connect()` returns (`players/all` and the like), so wait for the log to
        // settle, then bracket the probe between two reads of the summaries: the probe's list must lie between them
        // (a late command can only extend the log). Under 20 commands, so `recentCommandSummaries`' suffix never drops one.
        let before = try await settledCommandSummaries(server)
        let json = model.testProbe().json
        let after = server.recentCommandSummaries()
        let probe = try JSONDecoder().decode(TestProbe.self, from: Data(json.utf8))
        XCTAssertEqual(probe.tokenStore, "memory")
        XCTAssertEqual(probe.lastExternalOpen, help.absoluteString)
        XCTAssertTrue(after.starts(with: probe.maRequests), "probe \(probe.maRequests) after \(after)")
        XCTAssertTrue(probe.maRequests.starts(with: before), "before \(before) probe \(probe.maRequests)")
        XCTAssertTrue(probe.maRequests.contains { $0.hasPrefix("auth") }, "\(probe.maRequests)")
        XCTAssertFalse(json.contains(ScriptedMusicAssistant.token.rawValue), json)
        XCTAssertFalse(json.contains("roadie-test-token"), json)
    }

    // MARK: Helpers

    /// The server's command summaries once they stop changing (unchanged across 300 ms), within 5 s.
    private func settledCommandSummaries(_ server: ScriptedMusicAssistant) async throws -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        var last = server.recentCommandSummaries()
        var stableSince = clock.now
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let current = server.recentCommandSummaries()
            if current != last {
                last = current
                stableSince = clock.now
            } else if stableSince.duration(to: clock.now) >= .milliseconds(300) {
                return current
            }
        }
        XCTFail("Music Assistant commands never settled: \(last)")
        return last
    }

    /// A temp data directory and defaults suite, Music Assistant `musicAssistant`, no discovery, recorded opens.
    private func testConfiguration(
        _ musicAssistant: RoadieConfiguration.MusicAssistantMode = .none
    ) throws -> RoadieConfiguration {
        let data = FileManager.default.temporaryDirectory.appending(path: "roadie-axid-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        folders.append(data)
        let suite = "co.sstools.roadie.tests.axid.\(UUID())"
        suiteNames.append(suite)
        var configuration = RoadieConfiguration()
        configuration.dataDirectory = data
        configuration.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        configuration.musicAssistant = musicAssistant
        configuration.museum = .fixtures(skinsFolder: data.appending(path: "MuseumSkins", directoryHint: .isDirectory))
        configuration.discovery = false
        configuration.externalOpens = .record
        return configuration
    }

    /// Three 2:30 tracks restored stopped (nothing plays) with `current` selected.
    private func modelWithThreeTracks(current: Int) -> PlayerModel {
        // A configuration failure is a test bug; `try!` keeps the call sites synchronous.
        let model = PlayerModel(configuration: try! testConfiguration())
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
