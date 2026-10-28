import XCTest

/// The Library's Playlists groups against the scripted Music Assistant (#0221). Run only in the Tart guest:
/// scripts/verify.sh --ui. Belongs in `MusicAssistantUITests` (#0206) once that class is on main.
final class PlaylistGroupsUITests: RoadieUITestCase {
    /// A playlist created in Roadie (owner "Music Assistant" on the server) lists under My Playlists and can be
    /// renamed and deleted; a recorded generated playlist stays under Built-in with both disabled.
    func testCreatedPlaylistIsUnderMyPlaylists() {
        launch(library: .none, scenario: "libraryIdle")
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        roadie.app.typeKey("l", modifierFlags: .command)
        let sidebar = roadie.element(AXID.Library.sidebar("playlists"))
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Library sidebar never appeared")
        roadie.click(sidebar)

        let builtIn = roadie.element(AXID.Library.playlistGroup("builtIn"))
        XCTAssertTrue(builtIn.waitForExistence(timeout: 10), "Built-in group never appeared")
        let newPlaylist = roadie.element("library.playlists.new")
        XCTAssertTrue(newPlaylist.waitForExistence(timeout: 5), "library.playlists.new missing")
        roadie.click(newPlaylist)
        let name = roadie.element("library.playlist.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "name sheet never appeared")
        name.typeText("Party")
        name.typeKey(.return, modifierFlags: [])

        let mine = roadie.element(AXID.Library.playlistGroup("mine"))
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "My Playlists group never appeared")
        let party = roadie.app.staticTexts["Party"].firstMatch
        XCTAssertTrue(party.waitForExistence(timeout: 10), "Party row never appeared")
        XCTAssertLessThan(mine.frame.minY, party.frame.minY, "Party is above My Playlists")
        XCTAssertLessThan(party.frame.minY, builtIn.frame.minY, "Party isn't above Built-in")

        assertEditing(party, enabled: true)
        let generated = roadie.app.staticTexts["All favorited tracks"].firstMatch
        XCTAssertTrue(generated.waitForExistence(timeout: 5), "recorded generated playlist missing")
        XCTAssertLessThan(builtIn.frame.minY, generated.frame.minY, "generated playlist isn't under Built-in")
        assertEditing(generated, enabled: false)
    }

    private func assertEditing(_ row: XCUIElement, enabled: Bool, file: StaticString = #filePath, line: UInt = #line) {
        row.rightClick()
        let rename = roadie.app.menuItems["Rename\u{2026}"].firstMatch
        let delete = roadie.app.menuItems["Delete\u{2026}"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "Rename… missing", file: file, line: line)
        XCTAssertEqual(rename.isEnabled, enabled, "Rename… enabled", file: file, line: line)
        XCTAssertEqual(delete.isEnabled, enabled, "Delete… enabled", file: file, line: line)
        roadie.app.typeKey(.escape, modifierFlags: [])
    }
}
