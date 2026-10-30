import XCTest

/// The menu bar (#0202, design §5.1). XCUITest exposes no key equivalents on menu items, so the titles are checked
/// here and the shortcuts by SkinKit's `MainMenuTests.shortcutsMatchMenuBar`; the shortcut tests below press them.
final class MenuBarUITests: RoadieUITestCase {
    private let menus: [String: [String]] = [
        "Roadie": ["About Roadie", "Check for Updates…", "Settings…", "Quit Roadie"],
        "File": ["Open…", "Add to Playlist…", "Open Skin…", "Load Playlist…", "Save Playlist…"],
        "Skins": ["Skin Library…", "Next Skin", "Previous Skin", "Random Skin"],
        "Playback": [
            "Library", "Previous", "Play", "Pause", "Stop", "Next", "Jump to File\u{2026}", "Seek Back 5 Seconds",
            "Seek Forward 5 Seconds", "Volume Up", "Volume Down", "Shuffle", "Repeat", "Save Queue as Playlist\u{2026}",
            "Load Playlist from Library\u{2026}", "Favorite Current Track",
        ],
        "Window": [
            "Library", "Player", "Windowshade", "Equalizer", "EQ Windowshade", "Playlist Windowshade", "Playlist Editor",
            "Visualization", "Visualization Settings\u{2026}", "Always on Top", "Double Size",
        ],
        "Help": ["Welcome to Roadie…", "Playlists and the Queue…"],
    ]

    private func launchIdle() {
        launch(windows: [.main, .equalizer, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
    }

    private func item(_ menu: String, _ title: String) -> XCUIElement {
        roadie.app.menuBars.menuBarItems[menu].menuItems[title]
    }

    func testMenuBarHasEveryItem() {
        launchIdle()
        for (menu, titles) in menus.sorted(by: { $0.key < $1.key }) {
            let bar = roadie.app.menuBars.menuBarItems[menu]
            XCTAssertTrue(bar.exists, "no \(menu) menu")
            bar.click()
            for title in titles {
                XCTAssertTrue(bar.menuItems[title].waitForExistence(timeout: 2), "\(menu) › \(title) missing")
            }
            closeMenus()
        }
    }

    func testMenuBarTransport() {
        launchPlaying()
        let app = roadie.app
        app.typeKey("c", modifierFlags: [.command, .control])
        expectState("paused")
        app.typeKey("x", modifierFlags: [.command, .control])
        expectState("playing")
        app.typeKey("v", modifierFlags: [.command, .control])
        expectState("stopped")
        guard let k = roadie.probe?.currentIndex else { return XCTFail("no current row; probe: \(roadie.probeJSON)") }
        app.typeKey("b", modifierFlags: [.command, .control])
        roadie.expectCurrentRow((k + 1) % 3)
        var j = roadie.stopPlayback() ?? 0
        if j == 0 {
            app.typeKey("b", modifierFlags: [.command, .control])
            j = roadie.stopPlayback() ?? 0
        }
        app.typeKey("z", modifierFlags: [.command, .control])
        roadie.expectCurrentRow(j - 1)
        // The same items by click.
        clickMenuBar("Playback", "Stop")
        expectState("stopped")
        clickMenuBar("Playback", "Play")
        expectState("playing")
    }

    func testSeekAndVolumeShortcuts() {
        launchPlaying()
        let app = roadie.app
        app.typeKey("c", modifierFlags: [.command, .control])
        expectState("paused")
        setSlider(.position, to: 0.6)
        XCTAssertTrue(roadie.wait { (self.percent(AXID.Main.position) ?? 0) >= 40 }, "seek to 60 % didn't take")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command, .control])
        XCTAssertTrue(roadie.wait { (self.percent(AXID.Main.position) ?? 100) <= 10 }, "⌃⌘← didn't seek back")

        let volume = percent(AXID.Main.volume) ?? 50
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [.command, .control])
        XCTAssertTrue(roadie.wait { (self.percent(AXID.Main.volume) ?? 0) > volume }, "⌃⌘↑ didn't raise the volume")
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command, .control])
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command, .control])
        XCTAssertTrue(roadie.wait { (self.percent(AXID.Main.volume) ?? 100) < volume }, "⌃⌘↓ didn't lower the volume")
    }

    func testWindowMenu() {
        launchIdle()
        let app = roadie.app
        // ⌘1 brings the player forward from another key window.
        clickTitleStrip(playlistWindow)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(element(AXID.Main.Title.menu).waitForExistence(timeout: 5), "⌘1 didn't make the player key")

        app.typeKey("w", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.Shade.Main.play).waitForExistence(timeout: 5), "⌃⌘W didn't shade the player")
        app.typeKey("w", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.Main.play).waitForExistence(timeout: 5), "⌃⌘W didn't unshade the player")
        app.typeKey("e", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.Shade.EQ.volume).waitForExistence(timeout: 5), "⌃⌘E didn't shade the equalizer")
        app.typeKey("e", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.EQ.on).waitForExistence(timeout: 5), "⌃⌘E didn't unshade the equalizer")
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.Shade.PL.title).waitForExistence(timeout: 5), "⌃⌘P didn't shade the playlist")
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.PL.scrollbar).waitForExistence(timeout: 5), "⌃⌘P didn't unshade the playlist")

        // XCUITest may not expose menu check marks (`checkMark`), so the probe's model state is the assertion.
        XCTAssertEqual(roadie.probe?.alwaysOnTop, false, "Always on Top at launch; probe: \(roadie.probeJSON)")
        expectMenuBarCheckMark("Window", "Always on Top", false)
        clickMenuBar("Window", "Always on Top")
        XCTAssertTrue(roadie.wait { self.roadie.probe?.alwaysOnTop == true }, "probe: \(roadie.probeJSON)")
        expectMenuBarCheckMark("Window", "Always on Top", true)
        XCTAssertEqual(roadie.probe?.doubleSize, false, "Double Size at launch; probe: \(roadie.probeJSON)")
        expectMenuBarCheckMark("Window", "Double Size", false)
        clickMenuBar("Window", "Double Size")
        XCTAssertTrue(roadie.wait { self.roadie.probe?.doubleSize == true }, "probe: \(roadie.probeJSON)")
        expectMenuBarCheckMark("Window", "Double Size", true)
    }

    func testCheckForUpdatesIsDisabledInDebug() {
        launchIdle()
        let bar = roadie.app.menuBars.menuBarItems["Roadie"]
        bar.click()
        let check = bar.menuItems["Check for Updates…"]
        XCTAssertTrue(check.waitForExistence(timeout: 2), "Roadie › Check for Updates… missing")
        XCTAssertFalse(check.isEnabled, "Roadie › Check for Updates… enabled in Debug")
        closeMenus()
        let menu = openPopUpMenu()
        XCTAssertFalse(menu.menuItems["Check for Updates…"].isEnabled, "pop-up Check for Updates… enabled in Debug")
        closeMenus()
    }

    func testAboutPanelOpens() {
        launchIdle()
        clickMenuBar("Roadie", "About Roadie")
        // The standard About panel (`orderFrontStandardAboutPanel`) opens, as run 20261024-233550-41225's screenshot
        // shows, but isn't in `app.windows` (an AXDialog-like panel), so look for it as a dialog or any window, by the
        // credits' text (Credits.rtf: "Roadie: a Winamp-skinned player for Music Assistant").
        var panel: XCUIElement?
        XCTAssertTrue(
            roadie.wait {
                panel = self.aboutPanel()
                return panel != nil
            }, "no About panel; app: \(roadie.app.debugDescription.prefix(1500))")
        guard let panel else { return }
        let close = panel.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists, "the About panel has no close button: \(roadie.describe(panel))")
        close.click()
        XCTAssertTrue(roadie.wait { self.aboutPanel() == nil }, "the About panel didn't close")
    }

    /// The About panel: a dialog or window holding the credits text, or nil.
    private func aboutPanel() -> XCUIElement? {
        let credits = NSPredicate(format: "value CONTAINS 'Winamp-skinned' OR label CONTAINS 'Winamp-skinned'")
        for type in [XCUIElement.ElementType.dialog, .window] {
            let match = roadie.app.descendants(matching: type).containing(credits).firstMatch
            if match.exists { return match }
        }
        let dialog = roadie.app.dialogs.firstMatch
        return dialog.exists ? dialog : nil
    }

    func testFileMenuItems() {
        launchIdle()
        let bar = roadie.app.menuBars.menuBarItems["File"]
        bar.click()
        for title in menus["File"] ?? [] {
            let item = bar.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 2), "File › \(title) missing")
            XCTAssertTrue(item.isEnabled, "File › \(title) disabled")
        }
        closeMenus()
        clickMenuBar("File", "Open…")
        expectPanelRequest("openFiles replace=true")
        clickMenuBar("File", "Add to Playlist…")
        expectPanelRequest("openFiles replace=false")
    }

    func testQuitStopsTheApp() {
        launchPlaying()
        roadie.app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(roadie.app.wait(for: .notRunning, timeout: 5), "⌘Q didn't quit")
        let queue = (dataDirectory as NSString).appendingPathComponent("queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue), "no queue.json after quit at \(queue)")
    }
}
