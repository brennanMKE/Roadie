import XCTest

/// Music Assistant flows over #0197's scripted server (#0206, design §5.5–§5.7, §5.10). Run only in the Tart guest.
///
/// The scripted library (`MusicAssistantKitStub/Fixtures`): artists 10,000 Maniacs, Aerosmith, The Airborne Toxic Event;
/// albums 27, 46, 272 (scrubbed to empty titles), album 27's one recorded track "Ghost In The Shell"
/// (library://track/132); playlists "500 Random tracks (from library)" (id 4, five recorded tracks), "All favorited
/// tracks" (1), "Infinite Mix (favorites)" (8). `queueLoaded` puts the recorded 14-row queue (Soul Coughing) on the
/// speaker 4K Apple TV (`ap223aed81fe30`), row 2 current; every row the server sends has `index: 0` (#0187).
///
/// `probe.maRequests` is the server's last 20 commands as `<last path component> key=value…` (queue and player ids
/// left out), so the tests look at what arrived after a point (`newRequests`), not at the whole log.
final class MusicAssistantUITests: RoadieUITestCase {
    // MARK: Fixture identifiers

    private let speaker = "ap223aed81fe30"
    private let speakerName = "4K Apple TV"
    private let livingRoom = "ap82fe09484ac9"
    private let album27 = AXID.Library.row("album", "library://album/27")
    private let album27URI = "library://album/27"
    private let track132 = AXID.Library.row("track", "library://track/132")
    private let playlist4 = AXID.Library.row("playlist", "library://playlist/4")
    private let playlist4URI = "library://playlist/4"
    private let playlist4Name = "500 Random tracks (from library)"
    private let playlist4Tracks = 5

    // MARK: Probe

    private var queue: [ProbeState.QueueItem] { roadie.probe?.queue ?? [] }
    private var titles: [String] { queue.map(\.title) }
    private var requests: [String] { roadie.probe?.maRequests ?? [] }

    /// The requests that appear more often now than in `before`. The log is the last 20 commands and the app polls
    /// `get` / `get_active_queue` about twice a second (run 20261029-223259-454), so an overlap match on the order
    /// lined up the repeating polls and hid new commands; counting each distinct summary doesn't.
    private func newRequests(since before: [String]) -> [String] {
        let after = requests
        var seen: [String: Int] = [:]
        for entry in before { seen[entry, default: 0] += 1 }
        var out: [String] = []
        for entry in after {
            if let n = seen[entry], n > 0 { seen[entry] = n - 1 } else { out.append(entry) }
        }
        return out
    }

    /// Waits for a request after `before` that is `prefix` or starts with it and a space, so `play_index index=5`
    /// doesn't match `index=50`, and that has each of `containing` as a whole ` key=value` (or ` key=`) token. Returns it.
    @discardableResult
    private func expectRequest(
        _ prefix: String, containing: [String] = [], since before: [String], timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) -> String? {
        func matches(_ entry: String) -> Bool {
            guard entry == prefix || entry.hasPrefix(prefix + " ") else { return false }
            return containing.allSatisfy { token in
                token.hasSuffix("=") ? entry.contains(" " + token) : entry.hasSuffix(" " + token) || entry.contains(" " + token + " ")
            }
        }
        var found: String?
        let ok = roadie.wait(timeout: timeout) {
            found = newRequests(since: before).first(where: matches)
            return found != nil
        }
        let also = containing.isEmpty ? "" : " with \(containing.joined(separator: " "))"
        XCTAssertTrue(
            ok, "no \"\(prefix)…\"\(also) request; new: \(newRequests(since: before)); probe: \(roadie.probeJSON)",
            file: file, line: line)
        return found
    }

    /// An expected failure that only `expectRequest`'s missing-request assertion for `prefix` satisfies; any other
    /// failure inside the block fails the test as usual.
    private func expectedMissingRequest(_ prefix: String) -> XCTExpectedFailure.Options {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("no \"\(prefix)") }
        return options
    }

    // MARK: Launch

    /// Music Assistant as the Library's source over `scenario`; waits for the main window.
    private func launchMA(
        _ scenario: String, windows: Windows = [.main, .playlist], extra: [String] = [], openFiles: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        launch(library: .musicAssistant, scenario: scenario, windows: windows, openFiles: openFiles, extra: extra)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared", file: file, line: line)
    }

    /// ⌘L, then waits until the Library is connected: the Playlists section (Music Assistant only) and no status view.
    private func openLibrary(file: StaticString = #filePath, line: UInt = #line) {
        roadie.app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(
            element(AXID.Library.sidebar("playlists")).waitForExistence(timeout: 15),
            "⌘L didn't show Music Assistant's Library (no Playlists section)", file: file, line: line)
        XCTAssertTrue(
            roadie.wait(timeout: 15) { !self.element("library.status").exists }, "the Library never connected: "
                + roadie.describe(element("library.status")), file: file, line: line)
    }

    /// Opens the Output popover and clicks `id`'s Only button, then waits for the probe to report it.
    private func selectOnly(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        openOutputPicker(file: file, line: line)
        let popover = roadie.app.popovers.firstMatch
        var only = popover.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == 'Only'", "library.output.\(id)")).firstMatch
        if !only.waitForExistence(timeout: 3), let name = outputNames[id] {
            // The row identifiers may not reach the popover's controls: each device row is a checkbox (its name) and
            // an Only button, in the same order.
            let boxes = popover.checkBoxes.allElementsBoundByIndex
            if let i = boxes.firstIndex(where: { $0.label == name })
                ?? boxes.firstIndex(where: { $0.label.hasPrefix(name) }) {
                only = popover.buttons.matching(NSPredicate(format: "label == 'Only'")).element(boundBy: i)
            }
        }
        XCTAssertTrue(
            only.waitForExistence(timeout: 5), "no Only button for \(id): \(roadie.describe(popover))",
            file: file, line: line)
        only.click()
        let expected = id == "this-mac" ? "thisMac" : id
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.roadie.probe?.output == expected }, "output isn't \(expected); probe: "
                + roadie.probeJSON, file: file, line: line)
        closePopover()
    }

    /// Output ids to their names in `players-all.json` (This Mac is the app's own).
    private var outputNames: [String: String] {
        ["this-mac": "This Mac", speaker: speakerName, livingRoom: "Living Room"]
    }

    /// Before a skinned pop-up (pl.menu.*): no Output popover left open, and the playlist window key. Run
    /// 20261029-223259-454's pop-ups never showed their entries with the Library window key.
    private func focusPlaylist(file: StaticString = #filePath, line: UInt = #line) {
        closePopover()
        clickTitleStrip(playlistWindow, dx: 0.3)
        XCTAssertTrue(
            roadie.wait(timeout: 5) { self.element(AXID.PL.titleClose).exists }, "the playlist window never became key",
            file: file, line: line)
    }

    private func openOutputPicker(file: StaticString = #filePath, line: UInt = #line) {
        let button = libraryWindow.descendants(matching: .any).matching(identifier: AXID.Library.output).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no library.output", file: file, line: line)
        button.click()
        XCTAssertTrue(
            roadie.app.popovers.firstMatch.waitForExistence(timeout: 5), "the Output popover never opened",
            file: file, line: line)
    }

    private func closePopover() {
        if roadie.app.popovers.firstMatch.exists { roadie.app.typeKey(.escape, modifierFlags: []) }
        _ = roadie.wait(timeout: 3) { !self.roadie.app.popovers.firstMatch.exists }
    }

    /// `queueLoaded` with the speaker selected: the editor shows its remote queue, row 2 current.
    private func launchOnSpeaker(file: StaticString = #filePath, line: UInt = #line) {
        launchMA("queueLoaded", file: file, line: line)
        openLibrary(file: file, line: line)
        if roadie.probe?.output != speaker { selectOnly(speaker, file: file, line: line) }
        XCTAssertTrue(
            roadie.wait(timeout: 15) { self.queue.count >= 12 && self.roadie.probe?.currentIndex == 2 },
            "the editor never showed the speaker's queue at row 2; probe: \(roadie.probeJSON)", file: file, line: line)
    }

    private func waitForCurrent(_ i: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.roadie.probe?.currentIndex == i }, "row \(i) never became current; probe: "
                + roadie.probeJSON, file: file, line: line)
        XCTAssertTrue(
            roadie.waitForValue(roadie.playlist.row(i), timeout: 5) { $0.contains("current=true") },
            "pl.row.\(i) isn't current: \(roadie.value(of: roadie.playlist.row(i)))", file: file, line: line)
    }

    private func showSection(_ section: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(AXID.Library.sidebar(section))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(section) section", file: file, line: line)
        roadie.click(row, file: file, line: line)
    }

    private func openSettings(tab: String, marker: String, file: StaticString = #filePath, line: UInt = #line) {
        roadie.app.typeKey(",", modifierFlags: .command)
        let button = roadie.app.toolbars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Settings has no \(tab) tab", file: file, line: line)
        button.click()
        XCTAssertTrue(
            element(marker).waitForExistence(timeout: 10), "the \(tab) tab never showed \(marker)", file: file, line: line)
    }

    /// An element's value and label together.
    private func text(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return roadie.value(of: element) + " " + element.label
    }

    // MARK: Connecting

    func testConnectsAtLaunch() {
        launchMA("queueLoaded")
        openLibrary()
        // The probe keeps the last 20 commands and the app polls get / get_active_queue, so `auth` has scrolled out
        // by now (run 20261029-223259-454); testBadTokenShowsTheRefusalInTheLibrary and testThisMacPlaysMusicAssistant see it.
        let log = requests
        // players/all and player_queues/all both summarise as "all".
        XCTAssertTrue(log.contains("all"), "no players/all: \(log)")
        XCTAssertTrue(log.contains { $0.hasPrefix("library_items") }, "the Library didn't browse: \(log)")

        openSettings(tab: "Music Assistant", marker: "ma.servers")
        let servers = element("ma.servers")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.roadie.textExists("Scripted Music Assistant", in: servers) },
            "Settings doesn't list the seeded server: \(roadie.describe(servers))")
        XCTAssertTrue(roadie.textExists("In Use", in: servers), "the seeded server isn't In Use: \(roadie.describe(servers))")
        let reason = element("ma.reason")
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "no ma.reason")
        // MusicAssistantServerRanking.reason(for:): "<name> — first reachable" (or "on network …", "via Tailscale").
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.text(of: reason).contains("Scripted Music Assistant \u{2014}") },
            "ma.reason doesn't name the chosen server: \(text(of: reason))")
    }

    /// The refusal shows in the Library's failure view. Settings' `ma.reason` can't carry it: it is the server
    /// ranking's reason (`MusicAssistantServerRanking.Outcome` is reachability only, with no token outcome).
    func testBadTokenShowsTheRefusalInTheLibrary() {
        launchMA("badToken")
        roadie.app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(
            roadie.wait(timeout: 20) { self.libraryShows("Can't open the library") },
            "no failure in the Library; probe: \(roadie.probeJSON)")
        // The backend maps MusicAssistantError.tokenRejected to MusicBackendError.unauthorized, whose text the
        // browser shows: "The music source rejected the sign-in."
        XCTAssertTrue(
            libraryShows("rejected the sign-in"),
            "the failure doesn't say the token was refused: \(roadie.describe(libraryWindow))")
        XCTAssertTrue(
            libraryControl("Open Settings\u{2026}").exists || libraryControl("Retry").exists,
            "the failure offers neither Open Settings… nor Retry: \(roadie.describe(libraryWindow))")
        let log = requests
        XCTAssertTrue(log.contains("auth"), "no auth request: \(log)")
        XCTAssertFalse(log.contains { $0.hasPrefix("library_items") }, "browsed after a refused token: \(log)")
    }

    // MARK: Browsing

    func testSidebarSections() {
        launchMA("libraryIdle")
        openLibrary()
        for section in ["artists", "albums", "playlists", "favorites"] {
            XCTAssertTrue(element(AXID.Library.sidebar(section)).exists, "no \(section) section")
        }
        // Discover and Radio have no recordings (#0197 has no recommendations or radio fixtures): noted, not asserted.
        let extras = ["discover", "radio"].map { "\($0): \(element(AXID.Library.sidebar($0)).exists)" }
        let note = XCTAttachment(string: extras.joined(separator: "\n"))
        note.name = "discover-radio"
        note.lifetime = .keepAlways
        add(note)

        showSection("artists")
        for name in ["10,000 Maniacs", "Aerosmith"] {
            XCTAssertTrue(roadie.wait(timeout: 10) { self.libraryShows(name) }, "Artists doesn't list \(name)")
        }
        showSection("albums")
        XCTAssertTrue(element(album27).waitForExistence(timeout: 10), "Albums doesn't list album 27")
        showSection("playlists")
        XCTAssertTrue(element(playlist4).waitForExistence(timeout: 10), "Playlists doesn't list \(playlist4Name)")
    }

    // MARK: Playing on a speaker

    func testPlayAlbumShowsRemoteQueue() {
        launchOnSpeaker()
        showSection("albums")
        let album = element(album27)
        XCTAssertTrue(album.waitForExistence(timeout: 10), "Albums doesn't list album 27")
        let before = requests
        roadie.doubleClick(album)
        expectRequest("play_media media=\(album27URI) option=replace", since: before)
        // Album 27's one recorded track replaces the 14 rows.
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.titles.count == 1 && self.titles[0].contains("Ghost In The Shell") },
            "the editor isn't album 27: \(titles)")
        waitForCurrent(0)
        XCTAssertTrue(
            roadie.waitForValue(roadie.main.marquee, timeout: 10) { $0.contains("Ghost In The Shell") },
            "marquee: \(roadie.value(of: roadie.main.marquee))")
        XCTAssertTrue(roadie.wait(timeout: 10) { self.roadie.probe?.state == "playing" }, "not playing: \(roadie.probeJSON)")
        XCTAssertEqual(roadie.probe?.output, speaker)
    }

    /// #0187: a double-click, Return and the row menu's Play send the row's queue position. The server sends `index: 0`
    /// on every row, so the old code (the row's `index` field) sent `play_index index=0`.
    func testDoubleClickRowSendsItsPosition() {
        launchOnSpeaker()
        var before = requests
        roadie.doubleClick(roadie.playlist.row(5))
        expectRequest("play_index index=5", since: before)
        waitForCurrent(5)

        roadie.click(roadie.playlist.row(7))
        before = requests
        roadie.app.typeKey(.return, modifierFlags: [])
        expectRequest("play_index index=7", since: before)
        waitForCurrent(7)

        before = requests
        roadie.playlist.row(1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let play = roadie.playlist.popUpMenuItem("Play")
        XCTAssertTrue(play.waitForExistence(timeout: 3), "the row menu has no Play")
        play.click()
        expectRequest("play_index index=1", since: before)
        waitForCurrent(1)
    }

    /// #0187: Jump to File plays the chosen row's position.
    func testJumpToFilePlaysTheChosenRow() {
        launchOnSpeaker()
        guard let target = titles.firstIndex(where: { $0.contains("Fully Retractable") }) else {
            return XCTFail("no Fully Retractable row: \(titles)")
        }
        XCTAssertEqual(target, 8, "fixture rows: \(titles)")
        focusMain()
        roadie.app.typeKey("j", modifierFlags: .command)
        XCTAssertTrue(element(AXID.Jump.search).waitForExistence(timeout: 5), "⌘J didn't open Jump to File")
        roadie.app.typeText("Retractable")
        XCTAssertTrue(
            roadie.wait { self.roadie.probe?.jump?.results == [target] }, "Jump to File results; probe: \(roadie.probeJSON)")
        let before = requests
        roadie.app.typeKey(.return, modifierFlags: [])
        expectRequest("play_index index=\(target)", since: before)
        waitForCurrent(target)
    }

    func testQueueEdits() {
        launchOnSpeaker()
        // Delete: row 3 goes.
        var start = titles
        roadie.click(roadie.playlist.row(3))
        var before = requests
        roadie.app.typeKey(.delete, modifierFlags: [])
        expectRequest("delete_item", containing: ["item_id_or_index="], since: before)
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.titles.count == start.count - 1 && self.titles[3] == start[4] },
            "row 3 wasn't removed: \(titles)")

        // Drag row 9 onto row 4: move_item, the row lands at 4.
        start = titles
        before = requests
        roadie.playlist.row(9).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: roadie.playlist.row(4).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        expectRequest("move_item", since: before)
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.titles.count == start.count && self.titles[4] == start[9] },
            "row 9 didn't move to 4: \(titles)")

        // Q: row 10 moves to after the current row (#0182).
        start = titles
        let current = roadie.probe?.currentIndex ?? 2
        roadie.click(roadie.playlist.row(10))
        before = requests
        roadie.app.typeKey("q", modifierFlags: [])
        expectRequest("move_item", since: before)
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.titles.count == start.count && self.titles[current + 1] == start[10] },
            "Q didn't move row 10 after the current row \(current): \(titles)")

        // REM › Remove All: clear.
        before = requests
        roadie.playlist.menu(AXID.PL.Menu.rem, "pl.menu.rem.all")
        expectRequest("clear", since: before)
        XCTAssertTrue(roadie.wait(timeout: 10) { self.titles.isEmpty }, "the queue didn't empty: \(titles)")
    }

    func testSortIsRefusedOnARemoteQueue() {
        launchOnSpeaker()
        let start = titles
        let before = requests
        focusPlaylist()
        roadie.playlist.menu(AXID.PL.Menu.misc, "pl.menu.misc.sort")
        XCTAssertTrue(
            roadie.wait(timeout: 5) {
                (self.roadie.probe?.notice ?? "").contains("Not for Music Assistant")
                    || self.roadie.value(of: self.roadie.main.marquee).contains("Not for Music Assistant")
            }, "no refusal notice; probe: \(roadie.probeJSON)")
        for title in ["Sort by Title", "Reverse List", "Randomize List"] {
            let item = roadie.playlist.popUpMenuItem(title)
            if item.waitForExistence(timeout: 3) {
                XCTAssertFalse(item.isEnabled, "\(title) is enabled on a Music Assistant queue")
            } else {
                XCTFail("SORT LIST has no \(title)")
            }
        }
        roadie.app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(titles, start, "the remote queue changed")
        XCTAssertFalse(newRequests(since: before).contains { $0.hasPrefix("move_item") }, "a sort sent moves")
    }

    func testTransportOnSpeaker() {
        launchOnSpeaker()
        var before = requests
        roadie.click(element(AXID.Main.pause))
        // The pause button sends players/cmd/play_pause on a speaker.
        expectRequest("play_pause", since: before)
        XCTAssertTrue(roadie.wait(timeout: 10) { self.roadie.probe?.state == "paused" }, "not paused: \(roadie.probeJSON)")

        before = requests
        roadie.click(roadie.main.next)
        expectRequest("next", since: before)
        waitForCurrent(3)

        // Playback › Volume Up (⌃⌘↑) goes to the speaker.
        before = requests
        roadie.app.typeKey(.upArrow, modifierFlags: [.command, .control])
        expectRequest("volume_set", since: before)
    }

    /// A server-side track change (the queue's `next`, answered with `player_updated` and `queue_updated`) changes the
    /// marquee. Elapsed time isn't checked: main.time sat at the current track's length (03:06 for Circles, run
    /// 20261029-223259-454), most likely because the scripted server's `elapsed_time_last_updated` is the recording's
    /// epoch plus uptime, so the app extrapolates past the end. #0254.
    func testNowPlayingFollowsTheServer() {
        launchOnSpeaker()
        let marquee = roadie.value(of: roadie.main.marquee)
        roadie.click(roadie.main.next)
        XCTAssertTrue(
            roadie.waitForValue(roadie.main.marquee, timeout: 10) { $0 != marquee && $0.contains(self.nextTitle) },
            "the marquee didn't follow the server: \(roadie.value(of: roadie.main.marquee))")
    }

    /// Row 3's song title (rows are "Soul Coughing - <title>").
    private var nextTitle: String {
        let rows = titles
        guard rows.count > 3 else { return "\u{0}" }
        return rows[3].components(separatedBy: " - ").last ?? rows[3]
    }

    // MARK: Playlists (#0189, #0190)

    /// #0189: a double-click on a Music Assistant playlist plays it.
    func testDoubleClickPlaylistPlays() {
        launchOnSpeaker()
        showSection("playlists")
        let title = roadie.app.staticTexts.matching(identifier: playlist4).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no \(playlist4Name)")
        let before = requests
        roadie.doubleClick(title)
        expectRequest("play_media media=\(playlist4URI) option=replace", since: before)
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.titles.count == self.playlist4Tracks },
            "the editor doesn't show the playlist's \(playlist4Tracks) tracks: \(titles)")
    }

    /// #0189: the playlist row's menu plays, queues next and appends.
    func testPlaylistRowMenu() {
        launchOnSpeaker()
        showSection("playlists")
        openLibraryMenu(playlist4)
        for title in ["Play", "Play Next", "Add to Queue", "New Playlist\u{2026}", "Rename\u{2026}", "Delete\u{2026}",
                      "Export as M3U8\u{2026}", "Import Playlist\u{2026}"] {
            XCTAssertTrue(libraryMenuItem(title).exists, "the playlist menu lacks \(title)")
        }
        var before = requests
        roadie.click(libraryMenuItem("Play Next"))
        expectRequest("play_media media=\(playlist4URI) option=next", since: before)

        openLibraryMenu(playlist4)
        before = requests
        roadie.click(libraryMenuItem("Add to Queue"))
        expectRequest("play_media media=\(playlist4URI) option=add", since: before)
    }

    /// #0189: a drag onto the editor appends on a Music Assistant queue (#0173 decision 4).
    func testDragPlaylistAppendsToQueue() {
        launchOnSpeaker()
        let count = titles.count
        showSection("playlists")
        let before = requests
        dragLibraryRow(playlist4, to: roadie.playlist.row(2))
        // #0251: the playlist row's double-click gesture (`simultaneousGesture(TapGesture(count: 2))`) blocks the drag,
        // as the album row's did before #0205. Run 20261029-223259-454 saw no play_media at all.
        let request = "play_media media=\(playlist4URI) option=add"
        var arrived: String?
        XCTExpectFailure(
            "#0251: the Music Assistant playlist row's double-click gesture blocks its drag",
            options: expectedMissingRequest(request)
        ) {
            arrived = expectRequest(request, since: before)
        }
        guard arrived != nil else { return }
        XCTAssertTrue(
            roadie.wait(timeout: 5) { self.titles.count == count + self.playlist4Tracks },
            "the queue didn't grow by \(playlist4Tracks): \(titles)")
    }

    /// #0190: LIST › Load on the local queue with a Music Assistant Library offers its playlists and a file. The
    /// load itself runs on a speaker: This Mac didn't play Music Assistant media in scripted mode (Sendspin is kept
    /// off there; see testThisMacPlaysMusicAssistant).
    func testListLoadOffersLibraryPlaylist() {
        launchMA("libraryIdle", extra: ["-LibraryFolderPath", paths.music], openFiles: toneAlbum)
        XCTAssertTrue(roadie.wait(timeout: 10) { self.queue.count == 3 }, "the local queue never loaded: \(roadie.probeJSON)")
        openLibrary()
        XCTAssertEqual(roadie.probe?.output, "thisMac")

        focusPlaylist()
        roadie.playlist.menu(AXID.PL.Menu.list, "pl.menu.list.load")
        let library = roadie.playlist.popUpMenuItem("Library Playlist\u{2026}")
        XCTAssertTrue(library.waitForExistence(timeout: 5), "LIST › Load didn't offer Library Playlist…")
        XCTAssertTrue(roadie.playlist.popUpMenuItem("Playlist File\u{2026}").exists, "LIST › Load didn't offer Playlist File…")
        library.click()
        var list = element("playlist.picker.list")
        XCTAssertTrue(list.waitForExistence(timeout: 10), "no playlist picker")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.roadie.textExists(self.playlist4Name, in: list) },
            "the picker doesn't list \(playlist4Name): \(roadie.describe(list))")
        roadie.app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(roadie.wait(timeout: 5) { !list.exists }, "Escape didn't close the picker")

        // On a speaker, Playback › Load Playlist from Library… opens the picker and Load plays the playlist there.
        selectOnly(livingRoom)
        let menu = roadie.app.menuBars.menuBarItems["Playback"]
        menu.click()
        let item = roadie.app.menuBars.menuItems["Load Playlist from Library\u{2026}"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Playback › Load Playlist from Library…")
        XCTAssertTrue(item.isEnabled, "Load Playlist from Library… is disabled")
        item.click()
        list = element("playlist.picker.list")
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the menu item didn't open the picker")
        let row = list.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", playlist4Name, playlist4Name))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the picker doesn't list \(playlist4Name): \(roadie.describe(list))")
        row.click()
        let before = requests
        let load = roadie.app.buttons["Load"].firstMatch
        XCTAssertTrue(roadie.wait { load.isEnabled }, "Load stays disabled")
        load.click()
        expectRequest("play_media media=\(playlist4URI) option=replace", since: before)
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.titles.count == self.playlist4Tracks }, "the editor isn't the playlist: \(titles)")
    }

    func testSaveQueueAsPlaylist() {
        launchOnSpeaker()
        let before = requests
        focusPlaylist()
        roadie.playlist.menu(AXID.PL.Menu.list, "pl.menu.list.save")
        let sheet = roadie.app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "no Save Queue sheet")
        let field = sheet.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the sheet has no name field")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Saved Coughing")
        sheet.buttons["Save"].click()
        expectRequest("save_as_playlist name=Saved Coughing", since: before)
        showSection("playlists")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.libraryShows("Saved Coughing") }, "the Playlists list lacks the new playlist")
    }

    /// Create, rename, add to and delete a playlist. Remove from Playlist and Export/Import aren't driven here.
    func testPlaylistCRUD() {
        launchMA("libraryIdle")
        openLibrary()
        showSection("playlists")
        var before = requests
        let new = element("library.playlists.new")
        XCTAssertTrue(new.waitForExistence(timeout: 5), "no New Playlist")
        roadie.click(new)
        let name = element("library.playlist.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no name sheet")
        name.typeText("Roadie Mix")
        name.typeKey(.return, modifierFlags: [])
        expectRequest("create_playlist", since: before)
        let row = roadie.app.staticTexts["Roadie Mix"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Roadie Mix never listed")

        row.rightClick()
        let rename = libraryMenuItem("Rename\u{2026}")
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "no Rename…")
        before = requests
        rename.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no rename sheet")
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Roadie Mix 2")
        name.typeKey(.return, modifierFlags: [])
        expectRequest("update", since: before)
        let renamed = roadie.app.staticTexts["Roadie Mix 2"].firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 10), "the rename didn't show")

        // Albums › album 27 › Ghost In The Shell › Add to Playlist ▸ Roadie Mix 2.
        showSection("albums")
        selectLibraryRow(album27)
        XCTAssertTrue(element(track132).waitForExistence(timeout: 10), "album 27 never showed its track")
        element(track132).rightClick()
        let add = libraryMenuItem("Add to Playlist")
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add to Playlist")
        add.hover()
        let target = libraryMenuItem("Roadie Mix 2")
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Add to Playlist doesn't offer Roadie Mix 2")
        before = requests
        target.click()
        expectRequest("add_playlist_tracks", since: before)

        showSection("playlists")
        XCTAssertTrue(renamed.waitForExistence(timeout: 10), "Roadie Mix 2 gone from Playlists")
        renamed.rightClick()
        let delete = libraryMenuItem("Delete\u{2026}")
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no Delete…")
        delete.click()
        let confirm = element("library.playlist.delete")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no delete confirmation")
        before = requests
        confirm.click()
        expectRequest("remove_item", containing: ["library_item_id=", "media_type=playlist"], since: before)
        XCTAssertTrue(roadie.wait(timeout: 10) { !renamed.exists }, "Roadie Mix 2 still listed")
    }

    // MARK: Favorites, outputs, This Mac

    func testFavorites() {
        launchOnSpeaker()
        showSection("albums")
        selectLibraryRow(album27)
        XCTAssertTrue(element(track132).waitForExistence(timeout: 10), "album 27 never showed its track")
        element(track132).rightClick()
        let favorite = libraryMenuItem("Favorite")
        XCTAssertTrue(favorite.waitForExistence(timeout: 5), "the track menu has no Favorite")
        var before = requests
        favorite.click()
        expectRequest("add_item item=library://track/132", since: before)

        showSection("favorites")
        let tracks = element("library.favorites.tracks")
        XCTAssertTrue(tracks.waitForExistence(timeout: 10), "no Favorites › Tracks")
        roadie.click(tracks)
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.libraryShows("Ghost In The Shell") }, "Favorites › Tracks lacks the track")

        // Playback › Favorite Current Track (⌃⌘L) on the speaker: players/add_currently_playing_to_favorites.
        before = requests
        roadie.app.typeKey("l", modifierFlags: [.command, .control])
        expectRequest("add_currently_playing_to_favorites", since: before)
    }

    func testOutputPicker() {
        launchOnSpeaker()
        openOutputPicker()
        let popover = roadie.app.popovers.firstMatch
        for name in ["This Mac", "Speakers", speakerName, "Living Room", "Kitchen"] {
            XCTAssertTrue(
                roadie.wait(timeout: 10) {
                    self.roadie.textExists(name, in: popover)
                        || popover.checkBoxes.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists
                },
                "the Output popover lacks \(name): \(roadie.describe(popover))")
        }
        // A second speaker syncs to the leader.
        let living = popover.checkBoxes
            .matching(NSPredicate(format: "label CONTAINS 'Living Room' AND NOT (label CONTAINS 'Display')")).firstMatch
        XCTAssertTrue(living.waitForExistence(timeout: 5), "no Living Room checkbox: \(roadie.describe(popover))")
        var before = requests
        living.click()
        expectRequest("set_members player_ids_to_add=\(livingRoom)", since: before)
        closePopover()

        // Only: the leader alone again.
        before = requests
        selectOnly(speaker)
        expectRequest("set_members player_ids_to_remove=\(livingRoom)", since: before)

        // This Mac: the editor leaves the speaker's queue.
        selectOnly("this-mac")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.roadie.probe?.output == "thisMac" && self.queue.count < 12 },
            "the editor still shows the speaker's queue on This Mac; probe: \(roadie.probeJSON)")
    }

    /// This Mac is a Music Assistant (Sendspin) player: an album played on it goes through Music Assistant. The stub
    /// doesn't stream audio, so the feed and the rows are what's checked.
    func testThisMacPlaysMusicAssistant() {
        launchMA("thisMacIsASendspinPlayer")
        openLibrary()
        XCTAssertEqual(roadie.probe?.output, "thisMac")
        showSection("albums")
        let album = element(album27)
        XCTAssertTrue(album.waitForExistence(timeout: 10), "Albums doesn't list album 27")
        let before = requests
        roadie.doubleClick(album)
        // Run 20261029-223259-454: the same double-click that plays album 27 on a speaker sent only `album_tracks`
        // here, no play_media, and the feed stayed local. Scripted mode keeps Sendspin off (PlayerModel's scripted
        // setup), which is the likely cause; it needs a scripted Sendspin before this can pass.
        let request = "play_media media=\(album27URI) option=replace"
        var arrived: String?
        XCTExpectFailure(
            "#0254: no scripted Sendspin, so This Mac can't play Music Assistant media in scripted mode",
            options: expectedMissingRequest(request)
        ) {
            arrived = expectRequest(request, since: before)
        }
        guard arrived != nil else { return }
        XCTAssertTrue(
            roadie.wait(timeout: 5) { self.roadie.probe?.feed == "musicAssistant" }, "This Mac's feed isn't Music Assistant: "
                + roadie.probeJSON)
    }
}

