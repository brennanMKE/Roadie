import XCTest

/// Jump to File on the local queue (#0204, design §5.6). Launches as `PlaylistUITests` does: the fixture music folder
/// queued stopped (`-RoadieOpenFiles`), so the rows are Other Artist's Single (a copy of Tone C, tagged so), Tone A…C,
/// Tone D, 05 Tone E, 06 Tone F. Titles and the current row come from the probe, and so do the panel's results
/// (`probe.jump`): XCUITest doesn't expose its table rows (run 20261029-200200-41710). The fixture tracks are short
/// and auto-advance, so a test checks the played row right away; the plays use the 2.0–2.5 s tracks (rows 1–3).
final class JumpToFileUITests: RoadieUITestCase {
    static let fixtureCount = 7

    // MARK: Helpers

    private func launchQueue() {
        launch(windows: [.main, .playlist], openFiles: [paths.music])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.queue.count == Self.fixtureCount },
            "queue never held \(Self.fixtureCount) rows; probe: \(roadie.probeJSON)")
    }

    private var queue: [ProbeState.QueueItem] { roadie.probe?.queue ?? [] }

    private var search: XCUIElement { element(AXID.Jump.search) }

    /// The panel's state; nil while it is closed.
    private var jump: ProbeState.JumpProbe? { roadie.probe?.jump }

    /// The first queue row whose title contains `text` (case-insensitive).
    private func queueIndex(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let i = rows(titled: text).first else {
            XCTFail("no queue row titled like \"\(text)\"; probe: \(roadie.probeJSON)", file: file, line: line)
            return 0
        }
        return i
    }

    private func rows(titled text: String) -> [Int] {
        let queue = queue
        return queue.indices.filter { queue[$0].title.localizedCaseInsensitiveContains(text) }
    }

    private func expectOpen(_ how: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(search.waitForExistence(timeout: 5), "\(how) didn't open Jump to File", file: file, line: line)
        XCTAssertTrue(
            roadie.wait { self.jump != nil }, "\(how): the probe has no panel; probe: \(roadie.probeJSON)",
            file: file, line: line)
    }

    private func expectClosed(_ how: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            roadie.wait { !self.search.exists && self.jump == nil }, "\(how) didn't close Jump to File",
            file: file, line: line)
    }

    /// Opens the panel with J from the main window.
    private func openWithJ(file: StaticString = #filePath, line: UInt = #line) {
        focusMain(file: file, line: line)
        roadie.app.typeKey("j", modifierFlags: [])
        expectOpen("J", file: file, line: line)
    }

    /// Replaces the search field's text (it keeps focus while the panel is open).
    private func type(_ text: String) {
        roadie.app.typeKey("a", modifierFlags: .command)
        roadie.app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        if !text.isEmpty { roadie.app.typeText(text) }
    }

    /// Waits until the panel's results (playlist rows, in list order) satisfy `predicate`, and returns them.
    @discardableResult
    private func expectResults(
        _ what: String, file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping ([Int]) -> Bool
    ) -> [Int] {
        let ok = roadie.wait { self.jump.map { predicate($0.results) } ?? false }
        XCTAssertTrue(ok, "Jump to File doesn't list \(what); probe: \(roadie.probeJSON)", file: file, line: line)
        return jump?.results ?? []
    }

    private func expectResults(_ rows: [Int], file: StaticString = #filePath, line: UInt = #line) {
        expectResults("rows \(rows)", file: file, line: line) { $0 == rows }
    }

    /// The middle of table row `row`, by position (the rows aren't in the accessibility tree, #0249): the table's top
    /// plus (row + 0.5) row heights, the height from the probe. The table isn't scrolled with a few results.
    private func tableRow(_ row: Int) -> XCUICoordinate {
        let height = jump?.rowHeight ?? 0
        XCTAssertGreaterThan(height, 0, "no row height; probe: \(roadie.probeJSON)")
        return element(AXID.Jump.table).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0))
            .withOffset(CGVector(dx: 0, dy: (Double(row) + 0.5) * height))
    }

    /// The Queue button's title as accessibility reads it (what's on screen).
    private var queueButtonTitle: String {
        let button = element(AXID.Jump.queue)
        guard button.exists else { return "" }
        return button.title.isEmpty ? button.label : button.title
    }

    /// Checks the panel closed, row `i` is current and playing (a short track can auto-advance, so `playing` shows
    /// the play started), and `pl.row.i` says current.
    private func expectPlayed(_ i: Int, _ how: String, file: StaticString = #filePath, line: UInt = #line) {
        expectClosed(how, file: file, line: line)
        XCTAssertTrue(
            roadie.wait { self.roadie.probe?.currentIndex == i && self.roadie.probe?.state == "playing" },
            "\(how): row \(i) isn't current and playing; probe: \(roadie.probeJSON)", file: file, line: line)
        XCTAssertTrue(
            roadie.waitForValue(roadie.playlist.row(i), timeout: 2) { $0.contains("current=true") },
            "\(how): pl.row.\(i) isn't current: \(roadie.value(of: roadie.playlist.row(i)))", file: file, line: line)
    }

    // MARK: Tests

    func testOpensWithJAndCommandJ() {
        launchQueue()
        openWithJ()
        if let focused = search.value(forKey: "hasKeyboardFocus") as? Bool {
            XCTAssertTrue(focused, "jump.search hasn't keyboard focus")
        }
        expectResults(Array(0..<Self.fixtureCount))
        roadie.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        expectClosed("Esc")

        // ⌘J is a menu-bar command, so it works with the Library window key.
        roadie.app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(
            element(AXID.Library.sidebar("albums")).waitForExistence(timeout: 10), "⌘L didn't open the Library window")
        roadie.app.typeKey("j", modifierFlags: .command)
        expectOpen("⌘J from the Library window")
        expectResults(Array(0..<Self.fixtureCount))
    }

    func testTypingFilters() {
        launchQueue()
        openWithJ()
        // Each word is a substring match over "artist - title", album and file name (`JumpToFileIndex`), so "c" also
        // hits row 5's "05 Tone E.flac": rows 0 (the Single, tagged Tone C), 3 (Tone C) and 5, in playlist order.
        // Tone A, B and D (mp3/m4a, Tone Album), and F (.wav) hold no "c".
        type("tone c")
        expectResults([0, 3, 5])
        // A file-name word: Single.m4a, row 0 (files before subfolders).
        type("single")
        expectResults([0])
        type("zzz")
        expectResults([])
        XCTAssertTrue(roadie.wait { self.jump?.empty == "No matches" }, "no-match text; probe: \(roadie.probeJSON)")
        let empty = element(AXID.Jump.empty)
        XCTAssertTrue(roadie.waitForValue(empty) { $0 == "No matches" }, "jump.empty: \(roadie.describe(empty))")
    }

    /// #0187: the chosen row plays, not another.
    func testReturnPlaysTheChosenRow() {
        launchQueue()
        // A file-name number picks one row: "tone b" lists every Tone Album track ("b" in "Album").
        let b = queueIndex("- Tone B")
        XCTAssertEqual(b, 2, "fixture titles: \(queue.map(\.title))")
        openWithJ()
        type("02")
        expectResults([b])
        roadie.app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        expectPlayed(b, "Return")
        let marquee = roadie.main.marquee
        XCTAssertTrue(
            roadie.waitForValue(marquee, timeout: 2) { $0.hasPrefix("\(b + 1). ") }, "marquee \"\(roadie.value(of: marquee))\"")

        // Double-click the second listed row. `doubleAction` plays the selection (else the first result) and ignores
        // the clicked row, so the click must select it: "tone c" lists [0, 3, 5] with table row 0 selected, so a
        // miss plays row 0 and a wrong row plays row 5.
        // Rows 0 (the Single, a copy of Tone C) and 3 share the title "Tone Artist - Tone C"; row 3 is the real one.
        let c = 3
        XCTAssertEqual(rows(titled: "- Tone C"), [0, c], "fixture titles: \(queue.map(\.title))")
        roadie.stopPlayback()
        openWithJ()
        type("tone c")
        expectResults([0, c, 5])
        let second = tableRow(1)
        second.click()
        XCTAssertTrue(roadie.wait { self.jump?.selected == [c] }, "the click didn't select row \(c); probe: \(roadie.probeJSON)")
        second.doubleClick()
        expectPlayed(c, "double-click")

        // Arrows with an empty query: ↑ to the top (the last pick stays selected), then ↓ twice.
        roadie.stopPlayback()
        openWithJ()
        type("")
        expectResults(Array(0..<Self.fixtureCount))
        for _ in 0..<Self.fixtureCount { roadie.app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: []) }
        roadie.app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        roadie.app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.jump?.selected == [2] }, "↓↓ selection; probe: \(roadie.probeJSON)")
        roadie.app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        expectPlayed(2, "↓↓ Return")
    }

    func testQueueButtonAndEscape() {
        launchQueue()
        let e = queueIndex("05 Tone E")
        XCTAssertEqual(e, 5, "fixture titles: \(queue.map(\.title))")
        openWithJ()
        // Only 05 Tone E.flac has "05" ("tone e" lists every row: "e" is in "Tone").
        type("05")
        expectResults([e])
        let button = element(AXID.Jump.queue)
        roadie.click(button)
        XCTAssertTrue(roadie.wait { self.queue[e].marker == "[1]" }, "Queue didn't mark row \(e); probe: \(roadie.probeJSON)")
        XCTAssertTrue(search.exists && jump != nil, "Queue closed the panel")
        XCTAssertTrue(
            roadie.waitForValue(roadie.playlist.row(e)) { $0.contains("marker=[1]") },
            "pl.row.\(e): \(roadie.value(of: roadie.playlist.row(e)))")
        XCTAssertTrue(roadie.wait { self.queueButtonTitle == "Dequeue" }, "jump.queue: \(roadie.describe(button))")
        roadie.click(button)
        XCTAssertTrue(roadie.wait { self.queue[e].marker == "" }, "Dequeue left a marker; probe: \(roadie.probeJSON)")
        XCTAssertTrue(roadie.wait { self.queueButtonTitle == "Queue" }, "jump.queue: \(roadie.describe(button))")
        roadie.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        expectClosed("Esc")
    }

    /// #0190: an empty playlist's panel points at the Library.
    func testEmptyStateMentionsTheLibrary() {
        launch(windows: [.main, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        XCTAssertTrue(roadie.wait { self.roadie.probe != nil }, "no probe")
        XCTAssertTrue(queue.isEmpty, "the queue isn't empty; probe: \(roadie.probeJSON)")
        focusMain()
        roadie.app.typeKey("j", modifierFlags: .command)
        expectOpen("⌘J")
        let empty = element(AXID.Jump.empty)
        XCTAssertTrue(roadie.waitForValue(empty) { $0.contains("Library") }, "jump.empty: \(roadie.describe(empty))")
        XCTAssertTrue(
            roadie.wait { self.jump?.results == [] && self.jump?.empty?.contains("Library") == true },
            "probe: \(roadie.probeJSON)")
    }

    func testMenuBarItemOpensIt() {
        launchQueue()
        clickMenuBar("Playback", "Jump to File\u{2026}")
        expectOpen("Playback › Jump to File…")
        roadie.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        expectClosed("Esc")

        let menu = openPopUpMenu()
        menu.menuItems["Playback"].hover()
        let item = menu.menuItems["Jump to File\u{2026}"]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "pop-up Playback › Jump to File… missing")
        item.click()
        expectOpen("the pop-up's Playback › Jump to File…")
        expectResults(Array(0..<Self.fixtureCount))
    }
}
