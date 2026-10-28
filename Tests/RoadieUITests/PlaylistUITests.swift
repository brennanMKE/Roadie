import XCTest

/// The playlist editor on the local queue (#0203, design §5.5 `PlaylistUITests`). Each test launches with the fixture
/// music folder in the queue (`-RoadieOpenFiles`, loaded stopped): `LocalTrackLoader` walks files before subfolders, so
/// that is the 7 tracks Single, Tone A…C, Tone D…F. Titles come from the probe (`PlaylistModel.displayName`, the same
/// string the rows draw), not from a hard-coded list.
///
/// The fixture tracks are 2.5 s and auto-advance (#0200 Gotchas), so after anything that plays, the tests check the
/// row right away or stop first, and read the current row from the probe.
final class PlaylistUITests: RoadieUITestCase {
    static let fixtureCount = 7

    // MARK: Helpers

    private func launchQueue(extra: [String] = [], files: String? = nil) {
        launch(windows: [.main, .playlist], extra: ["-RoadieOpenFiles", files ?? paths.music] + extra)
        waitForRows(files == nil ? Self.fixtureCount : nil)
    }

    private var dataDir: String { RoadieUIApp.dataDirectory(testName: testName, paths: paths) }

    private func row(_ i: Int) -> XCUIElement { roadie.playlist.row(i) }

    private var queue: [ProbeState.QueueItem] { roadie.probe?.queue ?? [] }

    private var titles: [String] { queue.map(\.title) }

    /// Waits for the queue to hold `count` rows (any non-empty count when nil).
    private func waitForRows(_ count: Int?, file: StaticString = #filePath, line: UInt = #line) {
        let ok = roadie.wait(timeout: 10) { count.map { queue.count == $0 } ?? !queue.isEmpty }
        XCTAssertTrue(ok, "queue never held \(count.map(String.init) ?? "any") rows; probe: \(roadie.probeJSON)",
                      file: file, line: line)
    }

    private func click(_ i: Int, _ modifiers: XCUIElement.KeyModifierFlags = [], file: StaticString = #filePath,
                       line: UInt = #line) {
        let element = row(i)
        XCTAssertTrue(element.waitForExistence(timeout: 5), "no \(AXID.PL.row(i))", file: file, line: line)
        if modifiers.isEmpty {
            roadie.click(element, file: file, line: line)
        } else {
            XCUIElement.perform(withKeyModifiers: modifiers) { roadie.click(element, file: file, line: line) }
        }
    }

    private func isSelected(_ i: Int) -> Bool { row(i).exists && row(i).isSelected }

    private func selected() -> Set<Int> { Set((0..<queue.count).filter(isSelected)) }

    private func expectSelection(_ rows: Set<Int>, file: StaticString = #filePath, line: UInt = #line) {
        let ok = roadie.wait(timeout: 3) { selected() == rows }
        XCTAssertTrue(ok, "selection is \(selected().sorted()), expected \(rows.sorted())", file: file, line: line)
    }

    private func menuItem(_ title: String) -> XCUIElement { roadie.app.menuItems[title].firstMatch }

    private func rowValue(_ i: Int) -> String { roadie.value(of: row(i)) }

    private func visibleRows() -> [Int] {
        let rows = roadie.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pl.row.'")).allElementsBoundByIndex
        return rows.compactMap { Int($0.identifier.dropFirst("pl.row.".count)) }.sorted()
    }

    /// Plays row `i` by double-click and waits until the probe names it current (before it can auto-advance).
    private func play(_ i: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(row(i).waitForExistence(timeout: 5), "no \(AXID.PL.row(i))", file: file, line: line)
        roadie.doubleClick(row(i), file: file, line: line)
        roadie.expectCurrentRow(i, file: file, line: line)
    }

    // MARK: Tests

    func testRowsShowTheQueue() {
        launchQueue()
        let titles = titles
        XCTAssertEqual(titles.count, Self.fixtureCount)
        for i in 0..<Self.fixtureCount {
            let label = row(i).label.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{00A0}")))
            XCTAssertEqual(label, "\(i + 1). \(titles[i])", "row \(i)")
            // Durations load asynchronously (blank until known), so poll for each row's.
            let expected = Self.displayedDuration(titles[i])
            XCTAssertTrue(roadie.waitForValue(row(i)) { $0.contains("duration=\(expected) ") },
                          "row \(i) (\(titles[i])): \(rowValue(i)), expected duration=\(expected)")
        }
        XCTAssertFalse(row(Self.fixtureCount).exists, "a row past the queue")
        // 2.0 + 2.5 + 2.5 + 2.0 + 0.75 + 0.75 + 0.5 s = about 11 s; nothing selected, so "0:00/0:11" (decoders may
        // report a little under or over the nominal lengths).
        let runningTime = roadie.element(AXID.PL.runningTime)
        XCTAssertTrue(roadie.waitForValue(runningTime) { $0.range(of: #"/0:1[0-2]$"#, options: .regularExpression) != nil },
                      "running time \(roadie.value(of: runningTime))")
    }

    /// The row's duration text for a fixture title (`PlaylistText.time` rounds down): Tone A and B are 2.5 s and Tone C
    /// (and Single, a copy of it) 2.0 s, so 0:02; Tone D and E are 0.75 s and Tone F 0.5 s, so 0:00
    /// (`scripts/make-test-audio.sh`).
    static func displayedDuration(_ title: String) -> String {
        ["A", "B", "C"].contains { title.hasSuffix("Tone \($0)") } ? "0:02" : "0:00"
    }

    func testSelection() {
        launchQueue()
        click(1)
        expectSelection([1])
        click(3, .command)
        expectSelection([1, 3])
        click(5, .shift)
        // `PlaylistSelection.shiftClick` extends from the anchor (the last plain or command click, row 3).
        let afterShift = selected()
        XCTAssertTrue(afterShift.isSuperset(of: [3, 4, 5]), "shift-click selection \(afterShift.sorted())")
        roadie.app.typeKey("a", modifierFlags: .command)
        expectSelection(Set(0..<Self.fixtureCount))
        roadie.playlist.menu(AXID.PL.Menu.sel, "pl.menu.sel.zero")
        expectSelection([])
        click(2)
        roadie.playlist.menu(AXID.PL.Menu.sel, "pl.menu.sel.invert")
        expectSelection(Set(0..<Self.fixtureCount).subtracting([2]))
    }

    /// #0187, local half: a double-click plays the row under the pointer, not row 0.
    func testDoubleClickPlaysThatRow() {
        launchQueue()
        let title = titles[3]
        play(3)
        XCTAssertTrue(roadie.waitForValue(row(3), timeout: 2) { $0.contains("current=true") }, rowValue(3))
        XCTAssertTrue(rowValue(0).contains("current=false"), rowValue(0))
        let marquee = roadie.value(of: roadie.main.marquee)
        XCTAssertTrue(marquee.contains(title) || marquee.hasPrefix("4. "), "marquee \(marquee), expected \(title)")
        roadie.stopPlayback()
        click(5)
        roadie.app.typeKey(.return, modifierFlags: [])
        roadie.expectCurrentRow(5)
    }

    func testRemoveCropClear() {
        launchQueue()
        let before = titles
        click(2)
        roadie.app.typeKey(.delete, modifierFlags: [])
        waitForRows(Self.fixtureCount - 1)
        XCTAssertEqual(titles[2], before[3])
        click(0)
        click(1, .shift)
        roadie.playlist.menu(AXID.PL.Menu.rem, "pl.menu.rem.crop")
        waitForRows(2)
        roadie.playlist.menu(AXID.PL.Menu.rem, "pl.menu.rem.all")
        waitForRows(0)
        XCTAssertFalse(row(0).exists)
        roadie.playlist.menu(AXID.PL.Menu.list, "pl.menu.list.new")
        waitForRows(0)
    }

    func testDragReordersRows() {
        launchQueue()
        let first = titles[0]
        play(0)
        roadie.stopPlayback()
        roadie.expectCurrentRow(0)
        XCTAssertTrue(row(0).waitForExistence(timeout: 3) && row(4).exists)
        let start = row(0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = row(4).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)
        XCTAssertTrue(roadie.wait { titles.count == Self.fixtureCount && titles[4] == first }, "titles \(titles)")
        roadie.expectCurrentRow(4)
    }

    func testScrollResizeShade() {
        launchQueue(extra: ["-RoadieAddFolder", paths.music])
        roadie.playlist.menu(AXID.PL.Menu.add, "pl.menu.add.dir")
        waitForRows(Self.fixtureCount * 2)
        roadie.playlist.menu(AXID.PL.Menu.add, "pl.menu.add.dir")
        let total = Self.fixtureCount * 3
        waitForRows(total)
        XCTAssertEqual(visibleRows().first, 0)
        let shown = visibleRows().count
        XCTAssertLessThan(shown, total, "every row fits: nothing to scroll")

        roadie.click(roadie.element(AXID.PL.scrollDown))
        XCTAssertTrue(roadie.wait { visibleRows().first == 4 }, "scroll down: first visible \(visibleRows())")
        XCTAssertFalse(row(0).exists)

        // The wheel toward the top brings row 0 back. The rows sit under `PlaylistListInputView`, so they have no hit
        // point: scroll at a coordinate (the first visible row's centre) instead. The sign of XCUITest's deltaY against
        // AppKit's isn't pinned down here, so if the first wheel went toward the end, wheel the other way.
        let wheelAt = row(visibleRows().first ?? 4).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        wheelAt.scroll(byDeltaX: 0, deltaY: 200)
        XCTAssertTrue(roadie.wait { visibleRows().first != 4 }, "the wheel didn't scroll: first visible \(visibleRows())")
        if (visibleRows().first ?? 0) > 4 { wheelAt.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(roadie.wait { visibleRows().first == 0 }, "wheel up: first visible \(visibleRows())")

        let bar = roadie.element(AXID.PL.scrollbar)
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            .press(forDuration: 0.1, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.2)))
        XCTAssertTrue(roadie.wait { visibleRows().last == total - 1 }, "scrollbar drag: visible \(visibleRows())")

        let resize = roadie.element(AXID.PL.resize)
        XCTAssertTrue(resize.exists, "no \(AXID.PL.resize)")
        resize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: resize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 7)))
        XCTAssertTrue(roadie.wait { visibleRows().count > shown }, "resize: still \(visibleRows().count) rows")

        play(visibleRows().first ?? 0)
        let current = roadie.probe?.currentIndex ?? 0
        let name = titles[current]
        roadie.app.typeKey("p", modifierFlags: [.command, .control])
        let shade = roadie.element(AXID.Shade.PL.title)
        XCTAssertTrue(shade.waitForExistence(timeout: 3), "⌃⌘P didn't shade the playlist")
        XCTAssertTrue(roadie.waitForValue(shade, timeout: 3) { !$0.isEmpty }, roadie.describe(shade))
        XCTAssertTrue(
            titles.contains { roadie.value(of: shade).contains($0.prefix(6)) } || roadie.value(of: shade).contains(name.prefix(6)),
            "shade shows \(roadie.value(of: shade))")
        roadie.app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(roadie.wait { !shade.exists && roadie.element(AXID.PL.scrollbar).exists }, "⌃⌘P didn't unshade")
    }

    /// ADD › Add URL adds a radio station only with a radio-capable source (#0147); the folder library has none, so on
    /// the local queue it does nothing (the plan's URL sheet doesn't exist; see #0203 `## Fix`).
    func testAddURL() {
        launchQueue()
        roadie.playlist.menu(AXID.PL.Menu.add, "pl.menu.add.url")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(queue.count, Self.fixtureCount)
        XCTAssertFalse(roadie.element(AXID.PL.Menu.entries["PLAYLIST_ADD_URL"]!.id).exists, "the menu stayed open")
        XCTAssertNotEqual(roadie.probe?.state, "loading")
    }

    func testSelectMenu() {
        launchQueue()
        for entry in ["pl.menu.sel.all", "pl.menu.sel.zero", "pl.menu.sel.invert"] {
            roadie.playlist.menu(AXID.PL.Menu.sel, entry)
        }
        // all, none, invert: everything selected again.
        expectSelection(Set(0..<Self.fixtureCount))
    }

    func testSortMenu() {
        launchQueue()
        let original = titles
        // SORT LIST pops at the pointer with `popUp(positioning:at:in: nil)`; its entries are under `app.menuItems` (#0230).
        func sort(_ item: String) {
            roadie.playlist.menu(AXID.PL.Menu.misc, "pl.menu.misc.sort")
            let entry = menuItem(item)
            guard entry.waitForExistence(timeout: 3) else { return XCTFail("SORT LIST has no \(item) menu item (#0230)") }
            entry.click()
        }
        sort("Reverse List")
        XCTAssertTrue(roadie.wait { titles == Array(original.reversed()) }, "reversed: \(titles)")
        sort("Sort by Title")
        XCTAssertTrue(roadie.wait { titles == titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending } },
                      "by title: \(titles)")
        let sorted = titles
        sort("Randomize List")
        if !roadie.wait(timeout: 2, { titles != sorted }) { sort("Randomize List") }
        XCTAssertTrue(roadie.wait { titles != sorted }, "randomize kept the order twice")
        XCTAssertEqual(titles.sorted(), sorted.sorted())
    }

    func testMiscOptionsMenu() {
        launchQueue()
        roadie.playlist.menu(AXID.PL.Menu.misc, "pl.menu.misc.options")
        let entry = menuItem("Generate HTML Playlist")
        guard entry.waitForExistence(timeout: 3) else {
            return XCTFail("MISC OPTIONS has no Generate HTML Playlist menu item (#0230)")
        }
        entry.click()
        XCTAssertTrue(roadie.wait { self.roadie.probe?.lastExternalOpen?.hasSuffix("Roadie%20Playlist.html") == true },
                      "Generate HTML Playlist opened \(roadie.probe?.lastExternalOpen ?? "nothing")")
    }

    func testFileInfoPanel() {
        launchQueue()
        let title = titles[0]
        click(0)
        roadie.playlist.menu(AXID.PL.Menu.misc, "pl.menu.misc.info")
        let panel = roadie.app.windows["File Info"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "MISC › File Info opened no File Info window")
        let texts = panel.staticTexts.allElementsBoundByIndex.map { "\($0.label) \(roadie.value(of: $0))" }.joined(separator: "|")
        XCTAssertTrue(texts.contains("Single") || texts.contains(title.split(separator: "-").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? title), "File Info shows \(texts)")
        panel.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(roadie.wait { !panel.exists }, "File Info didn't close")

        // The row menu's File Info… too.
        row(1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let info = menuItem("File Info…")
        XCTAssertTrue(info.waitForExistence(timeout: 3), "row menu has no File Info…")
        info.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "row menu File Info… opened nothing")
        panel.buttons[XCUIIdentifierCloseWindow].click()
    }

    func testListMenuLocal() throws {
        let saved = (dataDir as NSString).appendingPathComponent("Saved.m3u")
        launchQueue(extra: ["-RoadieSaveTo", saved, "-RoadieLoadList", saved])
        roadie.playlist.menu(AXID.PL.Menu.list, "pl.menu.list.save")
        XCTAssertTrue(roadie.wait { FileManager.default.fileExists(atPath: saved) }, "LIST › Save wrote no \(saved)")
        let text = try String(contentsOfFile: saved, encoding: .utf8)
        let entries = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(entries.count, Self.fixtureCount, text)
        roadie.playlist.menu(AXID.PL.Menu.rem, "pl.menu.rem.all")
        waitForRows(0)
        roadie.playlist.menu(AXID.PL.Menu.list, "pl.menu.list.load")
        waitForRows(Self.fixtureCount)
        roadie.stopPlayback()
    }

    func testBottomBar() {
        launchQueue()
        let state = roadie.element(AXID.Main.state)
        roadie.click(roadie.element(AXID.PL.Transport.play))
        XCTAssertTrue(roadie.wait { roadie.probe?.state == "playing" }, roadie.probeJSON)
        roadie.click(roadie.element(AXID.PL.Transport.pause))
        XCTAssertTrue(roadie.wait { roadie.probe?.state == "paused" }, roadie.probeJSON)
        XCTAssertTrue(roadie.waitForValue(state) { $0 == "paused" }, roadie.describe(state))
        roadie.click(roadie.element(AXID.PL.Transport.stop))
        XCTAssertTrue(roadie.wait { roadie.probe?.state == "stopped" }, roadie.probeJSON)
        let before = roadie.probe?.currentIndex ?? 0
        roadie.click(roadie.element(AXID.PL.Transport.next))
        XCTAssertTrue(roadie.wait { (roadie.probe?.currentIndex ?? before) != before }, "next didn't move: \(roadie.probeJSON)")
        roadie.stopPlayback()
        let afterNext = roadie.probe?.currentIndex ?? 0
        roadie.click(roadie.element(AXID.PL.Transport.previous))
        XCTAssertTrue(roadie.wait { (roadie.probe?.currentIndex ?? afterNext) != afterNext || afterNext == 0 },
                      "previous didn't move: \(roadie.probeJSON)")
        roadie.stopPlayback()
        let mini = roadie.element(AXID.PL.miniTime)
        XCTAssertTrue(roadie.wait { roadie.value(of: mini) == roadie.value(of: roadie.main.time) },
                      "pl.miniTime \(roadie.value(of: mini)) vs main.time \(roadie.value(of: roadie.main.time))")
    }

    func testRowMenu() {
        launchQueue()
        row(2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        for title in ["Play", "Queue", "Remove", "File Info…"] {
            XCTAssertTrue(menuItem(title).waitForExistence(timeout: 3), "row menu has no \(title)")
        }
        menuItem("Play").click()
        roadie.expectCurrentRow(2)
        roadie.stopPlayback()

        row(4).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(menuItem("Queue").waitForExistence(timeout: 3))
        menuItem("Queue").click()
        XCTAssertTrue(roadie.waitForValue(row(4)) { $0.contains("marker=[1]") }, rowValue(4))
        row(4).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(menuItem("Dequeue").waitForExistence(timeout: 3), "queued row's menu has no Dequeue")
        XCTAssertTrue(menuItem("Clear Queue").exists, "no Clear Queue with an up-next queue")
        let removed = titles[4]
        menuItem("Remove").click()
        waitForRows(Self.fixtureCount - 1)
        XCTAssertNotEqual(titles[4], removed)
    }

    func testQueueMarkers() {
        launchQueue()
        // Rows 2 and 3 (Tone B 2.5 s, Tone C 2.0 s): long enough that the probe sees each one current before it
        // auto-advances (Tone D–F are under a second).
        click(2)
        click(3, .command)
        roadie.app.typeKey("q", modifierFlags: [])
        XCTAssertTrue(roadie.wait { queue.count > 3 && queue[2].marker == "[1]" && queue[3].marker == "[2]" },
                      "markers: \(queue.map(\.marker))")
        // A plain press on a row that's already selected keeps the whole selection (so a block can be dragged,
        // `PlaylistListInputView.mouseDown`): select another row first so the next click leaves only row 2.
        click(0)
        click(2)
        expectSelection([2])
        roadie.app.typeKey("q", modifierFlags: [])
        XCTAssertTrue(roadie.wait { queue[2].marker.isEmpty && queue[3].marker == "[1]" }, "markers: \(queue.map(\.marker))")
        // Up next wins over the list order; unshuffled, the list then carries on after the queued row that played
        // (`UpNextTests.upNextPlaysBeforeListOrderAndEmpties`: t1, then t4, t2, then t3), so row 3 then row 4.
        // The fixture tracks auto-advance in seconds (run 20261024-235522-51106 read row 6), so each skip (⌃⌘B) is
        // followed at once by Stop (⌃⌘V): both are menu commands handled in order on the main thread, so the player
        // stops on the row the skip chose, and the stopped current index is read without a race.
        play(0)
        roadie.stopPlayback()
        roadie.app.typeKey("b", modifierFlags: [.command, .control])
        roadie.stopPlayback()
        roadie.expectCurrentRow(3)   // stopped, so polling can't race an auto-advance
        // Row 3 left the play-next list when it played: no markers remain.
        XCTAssertTrue(roadie.wait { queue.allSatisfy { $0.marker.isEmpty } }, "markers: \(queue.map(\.marker))")
        roadie.app.typeKey("b", modifierFlags: [.command, .control])
        roadie.stopPlayback()
        roadie.expectCurrentRow(4)
    }

    func testQueueSurvivesRelaunch() {
        launchQueue()
        play(3)
        roadie.app.typeKey("c", modifierFlags: [.command, .control])
        XCTAssertTrue(roadie.wait { roadie.probe?.state == "paused" }, roadie.probeJSON)
        guard let current = roadie.probe?.currentIndex else { return XCTFail("no current row: \(roadie.probeJSON)") }
        // Let the autosaver write queue.json.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        roadie.terminate()
        launch(windows: [.main, .playlist])  // The data directory survives relaunches (the app makes it, #0208).
        waitForRows(Self.fixtureCount)
        roadie.expectCurrentRow(current)
        XCTAssertEqual(roadie.probe?.state, "stopped")
        XCTAssertTrue(rowValue(current).contains("current=true"), rowValue(current))
    }

    func testOpenFilesReplacesTheQueue() {
        let album = (paths.music as NSString).appendingPathComponent("Tone Artist/Tone Album")
        let a = (album as NSString).appendingPathComponent("01 Tone A.mp3")
        let b = (album as NSString).appendingPathComponent("02 Tone B.mp3")
        let c = (album as NSString).appendingPathComponent("03 Tone C.m4a")
        launchQueue(extra: ["-RoadieAddFiles", c], files: "\(a)|\(b)")
        waitForRows(2)
        roadie.app.typeKey("o", modifierFlags: [.command, .option])
        waitForRows(3)
    }

    // MARK: The menu bar's Playlist menu (#0226)

    static let playlistMenuTitles = [
        "Add File…", "Add Folder…", "Add URL…", "Remove Selected", "Crop", "Clear Playlist", "Select All", "Select None",
        "Invert Selection", "Sort by Title", "Sort by File Name", "Sort by Path and File Name", "Reverse List",
        "Randomize List", "File Info…", "Generate HTML Playlist", "Load Playlist…", "Save Playlist…",
    ]

    private var playlistMenuBarItem: XCUIElement { roadie.app.menuBars.menuBarItems["Playlist"] }

    /// Opens the Playlist menu and returns its item `title` (the menu stays open).
    private func openPlaylistMenu(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let bar = playlistMenuBarItem
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no Playlist menu in the menu bar", file: file, line: line)
        bar.click()
        let item = bar.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Playlist menu has no \(title)", file: file, line: line)
        return item
    }

    private func playlistMenu(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        openPlaylistMenu(title, file: file, line: line).click()
    }

    /// Whether Playlist › `title` is enabled; closes the menu again.
    private func playlistMenuIsEnabled(_ title: String) -> Bool {
        let enabled = openPlaylistMenu(title).isEnabled
        roadie.app.typeKey(.escape, modifierFlags: [])
        return enabled
    }

    func testPlaylistMenuBarHasEveryCommand() {
        launchQueue()
        let bar = playlistMenuBarItem
        _ = openPlaylistMenu("Add File…")
        let titles = bar.menus.firstMatch.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
        roadie.app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(titles, Self.playlistMenuTitles)
        expectSelection([])
        XCTAssertFalse(playlistMenuIsEnabled("Remove Selected"), "Remove Selected with nothing selected")
        XCTAssertFalse(playlistMenuIsEnabled("Crop"), "Crop with nothing selected")
        XCTAssertTrue(playlistMenuIsEnabled("Clear Playlist"))
        XCTAssertTrue(playlistMenuIsEnabled("Sort by Title"))
    }

    func testPlaylistMenuBarEditsTheQueue() {
        launchQueue()
        let original = titles
        playlistMenu("Reverse List")
        XCTAssertTrue(roadie.wait { titles == Array(original.reversed()) }, "reversed: \(titles)")
        roadie.app.typeKey("1", modifierFlags: [.command, .option])
        XCTAssertTrue(roadie.wait { titles == titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending } },
                      "⌥⌘1 by title: \(titles)")
        let sorted = titles
        click(0)
        click(1, .shift)
        expectSelection([0, 1])
        playlistMenu("Crop")
        waitForRows(2)
        XCTAssertEqual(titles, Array(sorted.prefix(2)))
        expectSelection([0, 1])
        playlistMenu("Invert Selection")
        expectSelection([])
        playlistMenu("Clear Playlist")
        waitForRows(0)
        for title in ["Remove Selected", "Crop", "Clear Playlist"] {
            XCTAssertFalse(playlistMenuIsEnabled(title), "\(title) on an empty queue")
        }
    }

    func testPlaylistMenuBarLoadsAndSaves() throws {
        let saved = (dataDir as NSString).appendingPathComponent("MenuBar.m3u")
        launchQueue(extra: ["-RoadieSaveTo", saved, "-RoadieLoadList", saved])
        roadie.app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertTrue(roadie.wait { FileManager.default.fileExists(atPath: saved) }, "⌥⌘S wrote no \(saved)")
        let text = try String(contentsOfFile: saved, encoding: .utf8)
        let entries = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(entries.count, Self.fixtureCount, text)
        playlistMenu("Clear Playlist")
        waitForRows(0)
        roadie.app.typeKey("l", modifierFlags: [.command, .option])
        waitForRows(Self.fixtureCount)
        roadie.stopPlayback()
    }
}
