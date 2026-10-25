import XCTest

/// The UI-test harness's smoke tests (#0200). Run only in the Tart guest: scripts/verify.sh --ui.
final class SmokeUITests: RoadieUITestCase {
    func testLaunchesWithTheBaseSkinAndShowsTheMainWindow() {
        launch()
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        XCTAssertGreaterThanOrEqual(roadie.app.windows.count, 2, "expected the main and playlist windows")
        XCTAssertEqual(roadie.probe?.state, "stopped", "probe: \(roadie.probeJSON)")
        let marquee = roadie.main.marquee
        // The skin's font is upper case ("ROADIE" on screen); the value is the model's text, MarqueeText.idle.
        XCTAssertTrue(
            roadie.waitForValue(marquee) { $0.localizedCaseInsensitiveContains("Roadie") },
            "marquee value \"\(roadie.value(of: marquee))\": \(roadie.describe(marquee))")
    }

    func testSkinnedWindowsExposeEveryIdentifier() {
        // `-RoadieVolume 60`: a launch volume other than the player's default 100 %, so the value proves the argument.
        let launchVolume = 60
        launch(windows: [.main, .equalizer, .playlist], volume: launchVolume)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        XCTAssertTrue(roadie.probeElement.exists, "state.probe missing in UI-test mode")
        // SkinSlider is an AXSlider whose AXValue is the position in percent (step 2), so 60 % reads as "60".
        let volume = roadie.main.volume
        let expected = "\(launchVolume)"
        XCTAssertTrue(
            roadie.waitForValue(volume) { $0 == expected },
            "main.volume value \"\(roadie.value(of: volume))\", expected \(expected): \(roadie.describe(volume))")

        let ids = AXID.Main.alwaysPresent + AXID.EQ.alwaysPresent + AXID.PL.alwaysPresent
            + [AXID.PL.titleShade, AXID.PL.titleClose, AXID.PL.resize]
        for id in ids {
            XCTAssertEqual(roadie.count(id), 1, "identifier \(id)")
        }

        // Queue the three-track album and stop. This test is about identifiers and values, not transport: the
        // 2.5 s tracks auto-advance, so the rows are checked against whichever track the probe says is current.
        roadie.playToneAlbum()
        guard let current = roadie.stopPlayback() else {
            return XCTFail("no current track after stopping; probe: \(roadie.probeJSON)")
        }
        guard let queue = roadie.probe?.queue, queue.count == 3, (0..<3).contains(current) else {
            return XCTFail("expected three queued tracks and a current one; probe: \(roadie.probeJSON)")
        }
        for i in 0..<3 {
            let row = roadie.playlist.row(i)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "pl.row.\(i) missing")
            XCTAssertEqual(row.label, "\(i + 1). \(queue[i].title)", "pl.row.\(i) label")
            let value = roadie.value(of: row)
            XCTAssertNotNil(
                value.range(of: #"^marker= duration=\d+:\d{2} current=\#(i == current)$"#, options: .regularExpression),
                "pl.row.\(i) value \"\(value)\" (current is \(current)): \(roadie.describe(row)); probe: \(roadie.probeJSON)")
        }
        XCTAssertFalse(roadie.playlist.row(3).exists, "pl.row.3 exists with three tracks")
    }

    func testPlaysTheFixtureLibrary() {
        launch()
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        roadie.playToneAlbum()
        // The fixture tracks are 2.5 s and auto-advance, so the current row is whichever the probe names, not row 0.
        XCTAssertTrue(roadie.playlist.row(0).waitForExistence(timeout: 5), "pl.row.0 missing")
        XCTAssertTrue(
            roadie.wait(timeout: 3) {
                guard let current = roadie.probe?.currentIndex else { return false }
                return roadie.value(of: roadie.playlist.row(current)).hasSuffix("current=true")
            },
            "the probe's current row isn't marked current=true; probe: \(roadie.probeJSON)")
        let time = roadie.main.time
        XCTAssertTrue(
            roadie.waitForValue(time) { !$0.isEmpty }, "main.time has no value: \(roadie.describe(time))")
        // A smoke check only: any change passes, including the reset when the 7.5 s album ends and the clock clears,
        // so this proves the display updates while playing, not that time advances.
        let first = roadie.value(of: time)
        XCTAssertTrue(
            roadie.waitForValue(time, timeout: 3) { $0 != first },
            "main.time stayed \"\(first)\" for 3 s while playing (it moves across track changes too): \(roadie.describe(time)); probe: \(roadie.probeJSON)")
    }
}
