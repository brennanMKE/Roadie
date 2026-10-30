import XCTest

/// The Library window over the folder library, and Library → playlist editor drags (#0205, design §5.7). The Music
/// Assistant-only parts are #0206.
///
/// The fixture library (`scripts/make-test-library.sh`): Tone Artist (Tone Album: Tone A, B, C; Two Discs: Tone D, E on
/// disc 1, Tone F on disc 2) and Other Artist (the synthetic "Singles" album holding Single.m4a, a copy of 03 Tone C.m4a,
/// so its tag title is "Tone C"). Folder IDs are relative paths (`FolderIndexer`), so the row identifiers are known.
/// The queue at launch is Tone Album, stopped at row 0. Queue titles come from the probe.
final class LibraryUITests: RoadieUITestCase {
    // MARK: Fixture identifiers

    private let toneArtist = AXID.Library.row("artist", "Tone Artist")
    private let otherArtist = AXID.Library.row("artist", "Other Artist")
    private let toneAlbumRow = AXID.Library.row("album", "Tone Artist/Tone Album")
    private let twoDiscs = AXID.Library.row("album", "Tone Artist/Two Discs")
    private let singles = AXID.Library.row("album", "Other Artist")
    private let toneA = AXID.Library.row("track", "Tone Artist/Tone Album/01 Tone A.mp3")
    private let toneB = AXID.Library.row("track", "Tone Artist/Tone Album/02 Tone B.mp3")
    private let toneD = AXID.Library.row("track", "Tone Artist/Two Discs/Disc 1/04 Tone D.m4a")
    private let toneE = AXID.Library.row("track", "Tone Artist/Two Discs/Disc 1/05 Tone E.flac")
    private let toneF = AXID.Library.row("track", "Tone Artist/Two Discs/Disc 2/06 Tone F.wav")

    // MARK: Helpers

    private var queue: [ProbeState.QueueItem] { roadie.probe?.queue ?? [] }
    private var titles: [String] { queue.map(\.title) }

    /// The window's identifier is `library`; its title is "Library – <source>" (navigation title and subtitle).
    private var libraryWindow: XCUIElement { roadie.app.windows["library"] }

    /// The list row (an outline row) holding `id`. The identifier lands on every element inside the row (art, title,
    /// artist), so `element(id)` is the art image.
    private func listRow(_ id: String) -> XCUIElement {
        roadie.app.outlineRows.containing(.any, identifier: id).firstMatch
    }

    /// Selects a Library row with a click near its right end (setup, not the click under test).
    private func select(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = listRow(id)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row holding \(id)", file: file, line: line)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
    }

    /// Clicks a Library row's title, where a user clicks. #0205: an album row's double-click gesture covered the row's
    /// content (`FavoriteRow`'s content shape), so this click didn't select (open) the album.
    private func clickTitle(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = roadie.app.staticTexts.matching(identifier: id).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no title text for \(id)", file: file, line: line)
        title.click()
    }

    /// Whether the Library window shows `text`: any element's label (search results are buttons), or a static text's
    /// value (SwiftUI puts a Text's string there). The value query is static texts only: a `value` predicate over every
    /// element type timed out and stalled the app's accessibility (run 20261029-211021-71914); label queries didn't.
    private func shows(_ text: String) -> Bool {
        libraryWindow.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
            || libraryWindow.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.exists
    }

    /// Whether the Library window has an element whose label or (static text) value is exactly `text`.
    private func showsExactly(_ text: String) -> Bool {
        libraryWindow.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch.exists
            || libraryWindow.staticTexts.matching(NSPredicate(format: "value == %@", text)).firstMatch.exists
    }

    /// A control in the Library window by its label. The status view's `.accessibilityIdentifier("library.status")`
    /// overrides its buttons' own `library.retry` / `library.openSettings` (run 20261029-213920-81208), so they're
    /// found by title.
    private func control(_ label: String) -> XCUIElement {
        libraryWindow.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Launches with `files` queued (Tone Album by default) and waits for the queue.
    private func launchQueued(_ files: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let files = files ?? toneAlbum
        launch(windows: [.main, .playlist], openFiles: files)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared", file: file, line: line)
        waitForRows(files.count, file: file, line: line)
    }

    private func waitForRows(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            roadie.wait(timeout: 10) { queue.count == count }, "queue never held \(count) rows; probe: \(roadie.probeJSON)",
            file: file, line: line)
    }

    /// ⌘L, then waits for the Artists sidebar row and (indexing done) Tone Artist's row.
    private func openLibrary(file: StaticString = #filePath, line: UInt = #line) {
        roadie.app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(
            element(AXID.Library.sidebar("artists")).waitForExistence(timeout: 10), "⌘L didn't open the Library",
            file: file, line: line)
        XCTAssertTrue(
            element(toneArtist).waitForExistence(timeout: 20), "Tone Artist never listed (is ROADIE_TEST_MUSIC indexed?)",
            file: file, line: line)
    }

    /// The Albums section, then `album`'s tracks; waits for `track` (a row of it).
    private func showAlbum(_ album: String, waitingFor track: String, file: StaticString = #filePath, line: UInt = #line) {
        roadie.click(element(AXID.Library.sidebar("albums")), file: file, line: line)
        select(album, file: file, line: line)
        XCTAssertTrue(element(track).waitForExistence(timeout: 10), "\(album) never showed \(track)", file: file, line: line)
    }

    /// A context-menu item while the menu is open: under a window (SwiftUI's context menus) or the app's menus.
    private func menuItem(_ title: String) -> XCUIElement {
        let inWindows = roadie.app.windows.descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title == %@", title)).firstMatch
        if inWindows.exists { return inWindows }
        return roadie.app.menus.descendants(matching: .menuItem).matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    /// Right-clicks `id`'s row and waits for the menu (its Play item).
    private func openMenu(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(id)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(id)", file: file, line: line)
        row.rightClick()
        XCTAssertTrue(
            roadie.wait { menuItem("Play").exists }, "right-clicking \(id) showed no menu", file: file, line: line)
    }

    private func expectMenu(
        _ id: String, has present: [String], lacks absent: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        openMenu(id, file: file, line: line)
        for title in present {
            XCTAssertTrue(menuItem(title).exists, "\(id)'s menu lacks \(title)", file: file, line: line)
        }
        for title in absent {
            XCTAssertFalse(menuItem(title).exists, "\(id)'s menu has \(title) (folder library)", file: file, line: line)
        }
        closeMenus()
    }

    /// Presses `source` (a Library row) and drags it to `target`'s centre.
    private func drag(_ source: String, to target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // The row's first text (its title): the identifier is on every element of the row, the art image first.
        let row = roadie.app.staticTexts.matching(identifier: source).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(source)", file: file, line: line)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "no drop target \(target)", file: file, line: line)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.0, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func screenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: Tests

    func testCommandLOpensTheLibraryWithSearchFocused() {
        launchQueued()
        openLibrary()
        XCTAssertTrue(libraryWindow.exists, "no window with the identifier library")
        // The folder backend's capabilities are search, artwork and local output: Artists and Albums only.
        XCTAssertTrue(element(AXID.Library.sidebar("albums")).exists, "no Albums section")
        for absent in ["playlists", "favorites", "radio", "discover"] {
            XCTAssertFalse(element(AXID.Library.sidebar(absent)).exists, "the folder library shows \(absent)")
        }
        // Artists is the section shown: its list holds the artist rows.
        XCTAssertTrue(element(otherArtist).exists, "Artists isn't the section shown")
        // Typing with no click lands in the search field: it has focus.
        let search = roadie.app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no search field")
        roadie.app.typeText("two")
        XCTAssertTrue(
            roadie.wait { roadie.value(of: search).contains("two") },
            "typing after ⌘L didn't reach the search field: \(roadie.describe(search))")
    }

    func testBrowseArtistAlbumTracks() {
        launchQueued()
        openLibrary()
        clickTitle(toneArtist)
        XCTAssertTrue(element(toneAlbumRow).waitForExistence(timeout: 10), "Tone Artist didn't list Tone Album")
        XCTAssertTrue(element(twoDiscs).exists, "Tone Artist didn't list Two Discs")
        XCTAssertFalse(element(singles).exists, "Tone Artist lists Other Artist's Singles")
        // #0205 regression: a click on the album's title opens it.
        clickTitle(twoDiscs)
        XCTAssertTrue(element(toneD).waitForExistence(timeout: 10), "clicking Two Discs' title didn't open it")
        let rows = [toneD, toneE, toneF].map { element($0) }
        XCTAssertTrue(rows.allSatisfy(\.exists), "Two Discs lacks a track: \(rows.map(\.exists))")
        let tracks = roadie.app.outlineRows.containing(
            NSPredicate(format: "identifier BEGINSWITH 'library.row.track.'")).count
        XCTAssertEqual(tracks, 3, "Two Discs' track rows")
        let ys = rows.map(\.frame.minY)
        XCTAssertTrue(ys[0] < ys[1] && ys[1] < ys[2], "tracks aren't in disc order: \(ys)")

        clickTitle(otherArtist)
        XCTAssertTrue(element(singles).waitForExistence(timeout: 10), "Other Artist didn't list its Singles")
        XCTAssertFalse(element(twoDiscs).exists, "Other Artist lists Two Discs")
    }

    func testSearch() {
        launchQueued()
        openLibrary()
        let search = roadie.app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no search field")
        roadie.click(search)
        // Folder search is a case-insensitive substring of the artist name, album title and track title
        // (`FolderBackend.search`): "tone a" matches Tone Artist, Tone Album and the track Tone A, nothing else.
        search.typeText("tone a")
        let results = element("library.results")
        XCTAssertTrue(results.waitForExistence(timeout: 10), "no search results")
        XCTAssertTrue(roadie.wait(timeout: 10) { shows("Tone Album") }, "Albums lacks Tone Album")
        // The sidebar also says Artists and Albums, so only the Tracks header proves a section.
        XCTAssertTrue(shows("Tracks"), "no Tracks section: \(roadie.describe(results))")
        // Exact: "Tone A" is also a prefix of Tone Album and Tone Artist. Search result rows have no identifiers of
        // their own (the list's library.results overrides them).
        XCTAssertTrue(showsExactly("Tone A"), "Tracks lacks Tone A")
        for absent in ["Two Discs", "Tone B", "Singles"] {
            XCTAssertFalse(shows(absent), "\(absent) matched \"tone a\"")
        }
        // Clearing goes back to the section.
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertTrue(roadie.wait(timeout: 5) { !results.exists }, "the results stayed after clearing")
        XCTAssertTrue(element(otherArtist).waitForExistence(timeout: 5), "clearing didn't go back to Artists")
    }

    func testDoubleClickAlbumPlays() {
        // Two Discs queued, so Tone Album replacing it shows.
        launchQueued([
            music("Tone Artist/Two Discs/Disc 1/04 Tone D.m4a"), music("Tone Artist/Two Discs/Disc 1/05 Tone E.flac"),
            music("Tone Artist/Two Discs/Disc 2/06 Tone F.wav"),
        ])
        // Opens Albums and double-clicks Tone Album: the queue becomes the album, playing from row 0.
        roadie.playToneAlbum()
        XCTAssertTrue(
            roadie.wait { titles.count == 3 && titles[0].contains("Tone A") && titles[2].contains("Tone C") },
            "the queue isn't Tone Album: \(titles)")
        XCTAssertEqual(roadie.probe?.currentIndex, 0, "the album didn't play from row 0: \(roadie.probeJSON)")
        XCTAssertTrue(roadie.playlist.row(0).exists && roadie.playlist.row(2).exists, "the editor doesn't show 3 rows")

        // A track row plays within its album: with Tone Album queued, double-clicking Two Discs' Tone E makes the
        // queue Two Discs, current Tone E (row 1).
        select(twoDiscs)
        let row = element(toneE)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Two Discs never showed Tone E")
        roadie.doubleClick(row)
        XCTAssertTrue(
            roadie.wait {
                titles.count == 3 && titles[0].contains("Tone D") && titles[1].contains("Tone E")
                    && titles[2].contains("Tone F")
            }, "double-clicking Tone E didn't queue its album: \(titles)")
        roadie.expectCurrentRow(1)
    }

    /// #0205 regression: in an artist's albums (a NavigationStack), a click opens the album by pushing its tracks. The
    /// push mustn't take the double-click's second click, which has to reach the album list's primary action.
    func testDoubleClickAlbumInArtistDetailPlays() {
        launchQueued()
        openLibrary()
        clickTitle(toneArtist)
        let title = roadie.app.staticTexts.matching(identifier: twoDiscs).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Tone Artist didn't list Two Discs")
        roadie.doubleClick(title)
        XCTAssertTrue(
            roadie.wait(timeout: 10) {
                titles.count == 3 && titles[0].contains("Tone D") && titles[1].contains("Tone E")
                    && titles[2].contains("Tone F")
            }, "double-clicking Two Discs in Tone Artist didn't queue it: \(titles); probe: \(roadie.probeJSON)")
        roadie.expectCurrentRow(0)
        // The click also opened the album.
        XCTAssertTrue(element(toneD).waitForExistence(timeout: 10), "Two Discs didn't open")
    }

    func testContextMenus() {
        launchQueued()
        openLibrary()
        // Containers: Play / Play Next / Add to Queue; no Add to Playlist or Favorite on the folder library (no
        // playlist editing, no favourites).
        expectMenu(toneArtist, has: ["Play", "Play Next", "Add to Queue"], lacks: ["Add to Playlist", "Favorite"])
        showAlbum(twoDiscs, waitingFor: toneD)
        expectMenu(twoDiscs, has: ["Play", "Play Next", "Add to Queue"], lacks: ["Add to Playlist", "Favorite"])
        expectMenu(toneD, has: ["Play", "Play Next", "Add to Queue"], lacks: ["Add to Playlist", "Favorite"])

        // Play Next appends the track and puts it at the front of up-next (#0181): the editor marks it [1].
        openMenu(toneD)
        roadie.click(menuItem("Play Next"))
        XCTAssertTrue(
            roadie.wait {
                let rows = queue
                return rows.count == 4 && rows[3].title.contains("Tone D") && rows[3].marker == "[1]"
            },
            "Play Next didn't queue Tone D first in up-next; probe: \(roadie.probeJSON)")

        openMenu(toneE)
        roadie.click(menuItem("Add to Queue"))
        XCTAssertTrue(
            roadie.wait { titles.count == 5 && titles[4].contains("Tone E") }, "Add to Queue didn't append Tone E: \(titles)")
        XCTAssertEqual(queue.dropFirst(4).first?.marker, "", "Add to Queue put Tone E in up-next: \(roadie.probeJSON)")

        // The album menu acts on the clicked row, not the selection: with Tone Album selected, Two Discs' Add to Queue
        // appends Two Discs.
        select(toneAlbumRow)
        XCTAssertTrue(element(toneB).waitForExistence(timeout: 10), "Tone Album didn't open")
        openMenu(twoDiscs)
        roadie.click(menuItem("Add to Queue"))
        XCTAssertTrue(
            roadie.wait {
                titles.count == 8 && titles[5].contains("Tone D") && titles[6].contains("Tone E")
                    && titles[7].contains("Tone F")
            }, "Two Discs' Add to Queue didn't append Two Discs: \(titles)")
    }

    /// #0188: the drop from the Library onto the skinned editor's track list, at the row under the pointer. #0205
    /// regression: the album's double-click gesture blocked the drag.
    func testDragAlbumOntoPlaylistRow() {
        launchQueued()
        openLibrary()
        roadie.click(element(AXID.Library.sidebar("albums")))
        XCTAssertTrue(element(twoDiscs).waitForExistence(timeout: 10), "no Two Discs under Albums")
        drag(twoDiscs, to: roadie.playlist.row(1))
        screenshot("after dragging Two Discs onto pl.row.1")
        XCTAssertTrue(roadie.wait(timeout: 10) { titles.count == 6 }, "the drop didn't land: \(titles)")
        XCTAssertTrue(
            titles.count == 6 && titles[0].contains("Tone A") && titles[1].contains("Tone D")
                && titles[2].contains("Tone E") && titles[3].contains("Tone F") && titles[4].contains("Tone B"),
            "Two Discs wasn't inserted at row 1 in order: \(titles)")
        XCTAssertEqual(roadie.probe?.maRequests ?? [], [], "a local drop sent Music Assistant requests")
    }

    func testDragTrackOntoBottomBar() {
        launchQueued()
        openLibrary()
        showAlbum(twoDiscs, waitingFor: toneE)
        drag(toneE, to: element(AXID.PL.runningTime))
        XCTAssertTrue(
            roadie.wait(timeout: 10) { titles.count == 4 && titles[3].contains("Tone E") },
            "Tone E wasn't appended: \(titles)")
    }

    func testDragArtistOntoPlaylist() {
        launchQueued()
        openLibrary()
        drag(otherArtist, to: roadie.playlist.row(0))
        // Other Artist's only track is Single.m4a, tagged "Tone C".
        XCTAssertTrue(
            roadie.wait(timeout: 10) { titles.count == 4 && titles[0].contains("Tone C") && titles[1].contains("Tone A") },
            "Other Artist's single wasn't inserted at row 0: \(titles)")
    }

    /// Only that nothing changes: the test can't see that the drag began (the drag image isn't in the accessibility
    /// tree), so it also passes if the drag never starts. The other drag tests show the same drag does start.
    func testDragWithoutDropLeavesTheQueue() {
        launchQueued()
        let before = titles
        openLibrary()
        showAlbum(twoDiscs, waitingFor: toneD)
        drag(toneD, to: roadie.main.marquee)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(titles, before, "a drop on the main window changed the queue")
    }

    func testUnreachableSourceShowsRetry() {
        // A folder that doesn't exist: unreachable, so Retry (not Open Settings…).
        launch(library: .none, extra: ["-LibraryFolderPath", "/nonexistent", "-LibrarySource", "folder"])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        roadie.app.typeKey("l", modifierFlags: .command)
        let status = element("library.status")
        XCTAssertTrue(status.waitForExistence(timeout: 15), "no library.status")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { shows("Can't open the library") },
            "no \"Can't open the library\": \(roadie.describe(status))")
        XCTAssertTrue(control("Retry").waitForExistence(timeout: 5), "no Retry for an unreadable folder")
        XCTAssertFalse(control("Open Settings\u{2026}").exists, "Open Settings… for an unreadable folder")

        // No folder at all: not configured, so Open Settings…, which opens Settings on the Library tab.
        roadie.terminate()
        launch(library: .none, extra: ["-LibrarySource", "folder"])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared (relaunch)")
        roadie.app.typeKey("l", modifierFlags: .command)
        let open = control("Open Settings\u{2026}")
        XCTAssertTrue(open.waitForExistence(timeout: 15), "no Open Settings… with no folder")
        roadie.click(open)
        XCTAssertTrue(element("library.source").waitForExistence(timeout: 10), "Settings didn't open on the Library tab")
    }

    func testFallbackToFolderNotice() {
        // Music Assistant preferred (the later -LibrarySource wins) and unreachable, the folder configured.
        launch(scenario: "unreachable", windows: [.main, .playlist], extra: ["-LibrarySource", "musicAssistant"])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        roadie.app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(
            roadie.wait(timeout: 20) {
                (roadie.probe?.notice ?? "").hasPrefix("Using") || roadie.value(of: roadie.main.marquee).contains("Using")
            }, "no fallback notice; probe: \(roadie.probeJSON)")
        XCTAssertTrue(element(toneArtist).waitForExistence(timeout: 20), "the Library didn't fall back to the folder")
        XCTAssertFalse(element(AXID.Library.sidebar("playlists")).exists, "still on Music Assistant's sections")

        roadie.app.typeKey(",", modifierFlags: .command)
        let tab = roadie.app.toolbars.buttons["Library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Settings has no Library tab")
        tab.click()
        XCTAssertTrue(element("library.maReason").waitForExistence(timeout: 10), "Settings › Library shows no reason")
    }
}
