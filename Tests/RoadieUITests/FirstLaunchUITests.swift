import XCTest

/// The Welcome window (#0169) and the Help menu (#0191). #0209; design docs/design/test-automation.md §5.9. Run only in
/// the Tart guest: scripts/verify.sh --ui. Test mode keeps the app's defaults in its own suite and puts the default
/// skins folder in the test's data directory (`RoadieConfiguration.defaultSkinsFolder`), so no test touches `~/Roadie`.
final class FirstLaunchUITests: RoadieUITestCase {
    /// A fresh install: no skin, no skins folder, no music folder, Music Assistant `.none`. With no skin the main window
    /// shows "No Skin Loaded" (no `main.play`), so this waits for the Welcome window. The default skins folder is
    /// `<data>/<test>/Roadie/Skins`, created empty by the app, so the Welcome counts no skins and opens the Museum.
    private func launchFresh(extra: [String] = []) {
        launch(library: .none, firstRun: true, skinsFolder: .none, loadsSkin: false, extra: extra)
        XCTAssertTrue(welcome.waitForExistence(timeout: 15), "no Welcome window on a fresh install")
    }

    private var welcome: XCUIElement { roadie.app.windows.matching(identifier: "welcome").firstMatch }

    /// Any element in the Welcome window with this identifier.
    private func button(_ id: String) -> XCUIElement {
        welcome.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Help › Welcome to Roadie… brings the Welcome forward (the Museum or Settings opened over it) without reopening
    /// the Museum (`show(openMuseum: false)`).
    private func bringWelcomeForward() {
        let help = roadie.app.menuBars.menuBarItems["Help"]
        help.click()
        help.menuItems["Welcome to Roadie…"].click()
        XCTAssertTrue(welcome.waitForExistence(timeout: 5), "Help › Welcome to Roadie… didn't show the Welcome")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// The app's stored `firstRunVersion` (the probe reads the test suite's own domain; a `defaults read` from the test
    /// runner doesn't see the app's suite).
    private func expectFirstRunCompleted(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            roadie.wait(timeout: 10) { roadie.probe?.firstRunVersion == 1 },
            "firstRunVersion isn't 1; probe: \(roadie.probeJSON)", file: file, line: line)
    }

    /// The Skins window is up with the Museum segment selected (or the Museum's own status view showing).
    private func expectMuseum(file: StaticString = #filePath, line: UInt = #line) {
        let source = roadie.element(AXID.Skins.source)
        XCTAssertTrue(source.waitForExistence(timeout: 10), "the Skins window never opened", file: file, line: line)
        let museum = source.descendants(matching: .any)["Museum"]
        let selected = roadie.wait(timeout: 5) {
            (museum.exists && (museum.isSelected || roadie.value(of: museum) == "1"))
                || roadie.element("skins.museum.status").exists
        }
        XCTAssertTrue(selected, "Skins window isn't on the Museum tab: \(roadie.describe(source))", file: file, line: line)
    }

    /// Whether the Welcome shows `text` within `timeout`. A section header is a static text with a label and no value,
    /// a row's text has a value and no label, and one `value CONTAINS … OR label CONTAINS …` predicate never matched
    /// the headers (run 20261024-234816-47563), so the two are separate queries.
    private func hasText(_ text: String, timeout: TimeInterval = 5) -> Bool {
        roadie.wait(timeout: timeout) { roadie.textExists(text, in: welcome) }
    }

    func testWelcomeOnFreshDefaults() {
        launchFresh()
        // The section headers by identifier: a label search never found "Music Folder" (runs 20261024-234816-47563,
        // 20261025-000315-56017), so WelcomeView tags each header.
        for (id, header) in [
            ("welcome.header.skins", "Skins"), ("welcome.header.music", "Music Folder"),
            ("welcome.header.ma", "Music Assistant (optional)"),
        ] {
            let element = button(id)
            XCTAssertTrue(element.waitForExistence(timeout: 5), "Welcome lacks the \"\(header)\" section (\(id))")
            let text = element.label + " " + roadie.value(of: element)
            XCTAssertTrue(text.contains(header), "\(id) reads \"\(text)\", not \"\(header)\"")
        }
        let defaultFolder = "\(testName)/Roadie/Skins"
        XCTAssertTrue(hasText(defaultFolder, timeout: 5), "skins folder isn't <data>/\(defaultFolder)")
        XCTAssertTrue(hasText("0 skins", timeout: 10), "the default folder doesn't count 0 skins")
        XCTAssertNil(roadie.probe?.firstRunVersion, "firstRunVersion stored before Continue; probe: \(roadie.probeJSON)")
        // No skins in the default folder: the Welcome opened the Museum at once (the button: welcomeOpensMuseum).
        expectMuseum()

        // Open Skin… asks for the open panel (recorded, not shown, in test mode).
        bringWelcomeForward()
        roadie.click(button("welcome.skins.open"))
        XCTAssertTrue(
            roadie.wait { roadie.probe?.panelRequests?.contains("openSkin") == true },
            "Open Skin… asked for no panel; probe: \(roadie.probeJSON)")

        // Open Library is disabled with no music folder; the Music Assistant button opens Settings on its tab.
        bringWelcomeForward()
        XCTAssertFalse(button("welcome.music.openLibrary").isEnabled, "Open Library enabled with no music folder")
        roadie.click(button("welcome.ma.setup"))
        XCTAssertTrue(roadie.element("ma.servers").waitForExistence(timeout: 10), "Settings didn't open on Music Assistant")

        bringWelcomeForward()
        roadie.click(button("welcome.continue"))
        XCTAssertTrue(roadie.wait(timeout: 5) { !welcome.exists }, "Continue didn't close the Welcome")
        expectFirstRunCompleted()
    }

    func testExistingUserSkipsWelcome() {
        // lastSkinPath and skinsFolderPath set, firstRunVersion 0: an existing user (`.markCompleted`).
        launch(library: .none, firstRun: true)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        expectFirstRunCompleted()
        XCTAssertFalse(welcome.exists, "an existing user (lastSkinPath set) saw the Welcome")
    }

    func testWelcomeOpensMuseum() {
        launchFresh()
        // The empty default folder opens the Museum with the Welcome (welcomeOnFreshDefaults checks that); close it, so
        // the button's own Museum is what the check below sees.
        expectMuseum()
        let skinsWindow = roadie.app.windows.containing(NSPredicate(format: "identifier == %@", AXID.Skins.source)).firstMatch
        let close = skinsWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the Skins window has no close button")
        close.click()
        XCTAssertTrue(
            roadie.wait { !roadie.element(AXID.Skins.source).exists }, "the Skins window didn't close")
        bringWelcomeForward()
        roadie.click(button("welcome.skins.museum"))
        expectMuseum()
    }

    func testHelpMenu() {
        launch()
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        XCTAssertFalse(welcome.exists, "Welcome shown with firstRunVersion 1")
        let help = roadie.app.menuBars.menuBarItems["Help"]
        help.click()
        help.menuItems["Welcome to Roadie…"].click()
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), "Help › Welcome to Roadie… didn't open the Welcome")

        help.click()
        help.menuItems["Playlists and the Queue…"].click()
        let expected = "https://roadie.sstools.co/help.html#playlists"
        XCTAssertTrue(
            roadie.wait { roadie.probe?.lastExternalOpen == expected },
            "lastExternalOpen isn't \(expected); probe: \(roadie.probeJSON)")
    }

    func testChooseMusicFolderFromWelcome() {
        launchFresh(extra: ["-RoadieChooseFolder", paths.music])
        XCTAssertTrue(hasText("No folder chosen", timeout: 5), "music folder set before choosing")
        bringWelcomeForward()
        roadie.click(button("welcome.music.choose"))
        let folderName = (paths.music as NSString).lastPathComponent
        XCTAssertTrue(hasText(folderName, timeout: 10), "the music folder text never showed \(folderName)")
        XCTAssertTrue(hasText("track", timeout: 60), "the status never read the indexing result")
        XCTAssertTrue(
            roadie.wait(timeout: 5) { button("welcome.music.openLibrary").isEnabled }, "Open Library still disabled")
        roadie.click(button("welcome.music.openLibrary"))
        XCTAssertTrue(
            roadie.element(AXID.Library.sidebar("albums")).waitForExistence(timeout: 10),
            "Open Library didn't open the Library window")
    }
}
