import XCTest

/// The visualization window and its ways in (#0235). Run only in the Tart guest: scripts/verify.sh --ui.
final class VisualizationUITests: RoadieUITestCase {
    private static let visArguments = ["-RoadieVisRenderer", "classic", "-visualization.order", "sequential"]

    private var vis: RoadieUIApp.Visualization { roadie.visualization }

    private func launchPlain(extra: [String] = []) {
        launch(windows: [.main], extra: Self.visArguments + extra)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
    }

    /// The window opened and renders, showing `preset`.
    private func expectOpen(showing preset: String = "Classic Spectrum", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(vis.window.waitForExistence(timeout: 5), "vis.window never appeared", file: file, line: line)
        XCTAssertTrue(
            roadie.wait { self.vis.probe?.open == true && self.vis.probe?.rendering == true },
            "probe: \(roadie.probeJSON)", file: file, line: line)
        XCTAssertTrue(
            roadie.wait { self.vis.preset == preset }, "vis.preset is \"\(vis.preset)\", expected \(preset)",
            file: file, line: line)
    }

    private func expectClosed(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(roadie.wait { !self.vis.window.exists }, "vis.window still open", file: file, line: line)
        XCTAssertTrue(roadie.wait { self.vis.probe?.open == false }, "probe: \(roadie.probeJSON)", file: file, line: line)
    }

    /// An item of a menu popped in a window (the clutter bar's V, the right-click menus), by title.
    private func popUpMenuItem(_ title: String) -> XCUIElement {
        roadie.app.windows.descendants(matching: .menuItem).matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    func testCommandShiftKOpensAndClosesTheWindow() {
        launchPlain()
        XCTAssertNil(vis.probe, "probe has a visualization before it opened: \(roadie.probeJSON)")
        vis.open()
        expectOpen()
        XCTAssertEqual(vis.probe?.renderer, "classic")
        // The vis window is key now: the menu bar's ⇧⌘K works there too.
        roadie.app.typeKey("k", modifierFlags: [.command, .shift])
        expectClosed()
    }

    func testWindowMenuItemOpensTheWindow() {
        launchPlain()
        let windowMenu = roadie.app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 5), "no Window menu")
        windowMenu.click()
        let item = windowMenu.menuItems["Visualization"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Window menu has no Visualization")
        item.click()
        expectOpen()
    }

    func testClutterBarVMenuStartsTheVisualization() {
        launchPlain()
        roadie.click(roadie.element(AXID.Main.Clutter.v))
        let item = popUpMenuItem("Start/Stop Visualization")
        XCTAssertTrue(item.waitForExistence(timeout: 3), "the V menu has no Start/Stop Visualization")
        item.click()
        expectOpen()
    }

    func testMainMenuVisualizationSubmenu() {
        launchPlain()
        let button = roadie.element(AXID.Main.Title.menu)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(AXID.Main.Title.menu)")
        roadie.click(button)
        let sub = roadie.main.popUpMenu.menuItems["Visualization"]
        XCTAssertTrue(sub.waitForExistence(timeout: 3), "the main menu has no Visualization submenu")
        sub.hover()
        let entry = sub.menuItems["Start/Stop Visualization"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Visualization ▸ has no Start/Stop Visualization")
        entry.click()
        expectOpen()
    }

    func testRightClickOnTheBuiltInVisualizerShowsTheVisualizerMenu() {
        launchPlain()
        let visualizer = roadie.element(AXID.Main.visualizer)
        XCTAssertTrue(visualizer.waitForExistence(timeout: 5), "no \(AXID.Main.visualizer)")
        visualizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        for title in ["Spectrum Analyzer", "Oscilloscope", "Off", "Start/Stop Visualization"] {
            XCTAssertTrue(popUpMenuItem(title).waitForExistence(timeout: 3), "the visualizer menu has no \(title)")
        }
        XCTAssertFalse(popUpMenuItem("About Roadie").exists, "right-click on the visualizer showed the main menu")
        roadie.app.typeKey(.escape, modifierFlags: [])
    }

    func testWindowOpenAtLaunchWhenItWasOpen() {
        launchPlain(extra: ["-visualization.windowOpen", "YES", "-visualization.lastPreset", "classic:mirror"])
        expectOpen(showing: "Classic Mirror")
        XCTAssertEqual(vis.probe?.preset, "classic:mirror")
    }

    // MARK: Keys, auto-advance and the right-click menu (#0236)

    /// Opens the window (seed 1, sequential) and makes it key by clicking its title bar.
    private func openKeyWindow(extra: [String] = []) {
        launchPlain(extra: ["-RoadieVisSeed", "1"] + extra)
        vis.open()
        expectOpen()
        vis.window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
    }

    private func expectPreset(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            roadie.wait { self.vis.preset == name }, "vis.preset is \"\(vis.preset)\", expected \(name)",
            file: file, line: line)
    }

    func testArrowKeysMoveBetweenPresets() {
        openKeyWindow()
        roadie.app.typeKey(.rightArrow, modifierFlags: [])
        expectPreset("Classic Oscilloscope")
        roadie.app.typeKey(.rightArrow, modifierFlags: [])
        expectPreset("Classic Spectrum and Scope")
        roadie.app.typeKey(.leftArrow, modifierFlags: [])
        expectPreset("Classic Oscilloscope")
        XCTAssertEqual(vis.probe?.lastTransition, "blend 1.7")
    }

    func testSpaceAndDeleteMoveLikeTheArrows() {
        openKeyWindow()
        roadie.app.typeKey(" ", modifierFlags: [])
        expectPreset("Classic Oscilloscope")
        roadie.app.typeKey(.delete, modifierFlags: [])
        expectPreset("Classic Spectrum")
    }

    func testHCutsWithoutBlending() {
        openKeyWindow()
        roadie.app.typeKey("h", modifierFlags: [])
        expectPreset("Classic Oscilloscope")
        XCTAssertTrue(roadie.wait { self.vis.probe?.lastTransition == "cut" }, roadie.probeJSON)
    }

    func testRAndBacktickToggleOrderAndLock() {
        openKeyWindow()
        XCTAssertEqual(vis.probe?.order, "sequential")
        roadie.app.typeKey("r", modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.vis.probe?.order == "random" }, roadie.probeJSON)
        roadie.app.typeKey("r", modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.vis.probe?.order == "sequential" }, roadie.probeJSON)
        roadie.app.typeKey("`", modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.vis.probe?.locked == true }, roadie.probeJSON)
        roadie.app.typeKey("`", modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.vis.probe?.locked == false }, roadie.probeJSON)
    }

    func testTransportKeysWorkInTheVisualizationWindow() {
        openKeyWindow(extra: ["-RoadieOpenFiles", paths.music])
        XCTAssertTrue(roadie.wait { (self.roadie.probe?.queue.count ?? 0) > 0 }, "no queue: \(roadie.probeJSON)")
        roadie.app.typeKey("x", modifierFlags: [])
        roadie.waitForPlaying()
        roadie.app.typeKey("c", modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.roadie.probe?.state == "paused" }, roadie.probeJSON)
        roadie.app.typeKey("v", modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.roadie.probe?.state == "stopped" }, roadie.probeJSON)
    }

    func testPresetsChangeOnTheirOwn() {
        openKeyWindow(extra: ["-RoadieVisAutoAdvance", "2"])
        XCTAssertTrue(
            roadie.wait(timeout: 6) { (self.vis.probe?.presetChanges ?? 0) >= 1 }, "no automatic change: \(roadie.probeJSON)")
        XCTAssertEqual(vis.probe?.lastTransition, "blend 2.7")
        roadie.app.typeKey("`", modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.vis.probe?.locked == true }, roadie.probeJSON)
        let changes = vis.probe?.presetChanges
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(vis.probe?.presetChanges, changes, "changed while locked: \(roadie.probeJSON)")
    }

    func testRightClickMenuListsTheCommands() {
        openKeyWindow()
        let canvas = roadie.element(AXID.Vis.canvas)
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "no \(AXID.Vis.canvas)")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        for title in ["Next Preset", "Random Order", "Lock Preset"] {
            XCTAssertTrue(popUpMenuItem(title).waitForExistence(timeout: 3), "the menu has no \(title)")
        }
        popUpMenuItem("Next Preset").click()
        expectPreset("Classic Oscilloscope")
    }

    // MARK: Full screen (#0237)

    /// Full screen per the canvas filling the screen (the window is 640 pt wide, the guest's screen 1280+), or per
    /// the probe only when the canvas can't be read. Not the probe first: native full screen puts the vis window in
    /// its own Space, and the probe element in the main window drops out of the accessibility tree mid-transition,
    /// between `exists` and `value`, which failed the read with "No matches found" (#0238, run 20261029-054950-17473).
    private var isFullScreen: Bool? {
        let canvas = roadie.element(AXID.Vis.canvas)
        if canvas.exists { return canvas.frame.width >= 1000 }
        return vis.probe?.fullScreen
    }

    /// Full screen reaches `expected` within 5 s (native full screen animates).
    private func expectFullScreen(_ expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let reached = roadie.wait(timeout: 5) { self.isFullScreen == expected }
        if !reached {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "fullScreen-\(expected)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(reached, "probe fullScreen isn't \(expected): \(roadie.probeJSON)", file: file, line: line)
        // The canvas is screen-wide before the transition ends, and AppKit ignores a toggle mid-transition: wait
        // until its frame holds still between polls.
        let canvas = roadie.element(AXID.Vis.canvas)
        var last = CGRect.null
        _ = roadie.wait(timeout: 3) {
            let frame = canvas.exists ? canvas.frame : .null
            defer { last = frame }
            return frame == last
        }
    }

    private func openForFullScreen() {
        launchPlain()
        vis.open()
        expectOpen()
        XCTAssertEqual(vis.probe?.fullScreen, false)
    }

    func testOptionReturnTogglesFullScreen() {
        openForFullScreen()
        roadie.app.typeKey(.return, modifierFlags: .option)
        expectFullScreen(true)
        roadie.app.typeKey(.return, modifierFlags: .option)
        expectFullScreen(false)
    }

    func testEscapeLeavesFullScreen() {
        openForFullScreen()
        roadie.app.typeKey(.return, modifierFlags: .option)
        expectFullScreen(true)
        roadie.app.typeKey(.escape, modifierFlags: [])
        expectFullScreen(false)
    }

    func testDoubleClickTogglesFullScreen() {
        openForFullScreen()
        roadie.element(AXID.Vis.canvas).doubleClick()
        expectFullScreen(true)
        roadie.app.typeKey(.return, modifierFlags: .option)
        expectFullScreen(false)
    }

    // MARK: Song overlay (#0238)

    /// The idle timeout: long enough that the card is still up when XCUITest's query (about a second after a hover)
    /// lands, short enough that the hide checks don't wait long. Tests that only read the card use `readIdle`.
    private static let overlayIdle = ["-RoadieVisOverlayIdle", "3"]
    private static let readIdle = ["-RoadieVisOverlayIdle", "60"]

    private var overlayCard: XCUIElement { roadie.element(AXID.Vis.overlay) }

    /// Opens the window with the fixture music folder queued and playing (X in the vis window).
    private func openPlaying(idle: [String] = overlayIdle) {
        openKeyWindow(extra: ["-RoadieOpenFiles", paths.music] + idle)
        XCTAssertTrue(roadie.wait { (self.roadie.probe?.queue.count ?? 0) > 0 }, "no queue: \(roadie.probeJSON)")
        roadie.app.typeKey("x", modifierFlags: [])
        roadie.waitForPlaying()
    }

    /// The pointer over the canvas at `dx`, `dy` (normalized; the top half, clear of the card, which holds it up).
    /// Moves between two distinct points so there is real movement even when the pointer is already at `dx`, `dy`.
    private func hoverCanvas(_ dx: CGFloat = 0.5, _ dy: CGFloat = 0.3) {
        let canvas = roadie.element(AXID.Vis.canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: dx + 0.1, dy: dy + 0.05)).hover()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).hover()
    }

    /// The card hides by itself once the pointer rests (the idle timeout plus the fade and a query's latency).
    private func expectOverlayHides(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(roadie.wait(timeout: 10) { !self.overlayCard.exists }, message, file: file, line: line)
    }

    func testOverlayShowsTheSong() {
        openPlaying(idle: Self.readIdle)
        hoverCanvas()
        let title = roadie.element(AXID.Vis.Overlay.title)
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no \(AXID.Vis.Overlay.title): \(roadie.probeJSON)")
        let current = roadie.probe?.queue.first { $0.current }?.title ?? ""
        XCTAssertFalse(title.label.isEmpty)
        XCTAssertTrue(current.contains(title.label), "overlay title \"\(title.label)\", queue row \"\(current)\"")
        XCTAssertEqual(roadie.element(AXID.Vis.Overlay.state).label, "Playing")
        XCTAssertTrue(roadie.element(AXID.Vis.Overlay.output).label.contains("Volume"))
        XCTAssertTrue(roadie.element(AXID.Vis.Overlay.time).label.hasPrefix("Elapsed "))
    }

    func testOverlayHidesAfterIdleAndReturnsOnMovement() {
        openPlaying()
        hoverCanvas()
        XCTAssertTrue(overlayCard.waitForExistence(timeout: 5), "no \(AXID.Vis.overlay): \(roadie.probeJSON)")
        expectOverlayHides("the overlay didn't hide")
        XCTAssertTrue(
            roadie.wait { self.vis.probe?.overlay == "hidden" && self.vis.probe?.cursorHidden == true },
            "probe: \(roadie.probeJSON)")
        hoverCanvas(0.3, 0.15)
        XCTAssertTrue(overlayCard.waitForExistence(timeout: 3), "the overlay didn't come back on movement")
        XCTAssertEqual(vis.probe?.cursorHidden, false, roadie.probeJSON)
        // Full screen: the probe drops out of the tree there, so only the card is checked.
        roadie.app.typeKey(.return, modifierFlags: .option)
        expectFullScreen(true)
        hoverCanvas(0.5, 0.3)
        XCTAssertTrue(overlayCard.waitForExistence(timeout: 3), "no overlay in full screen")
        expectOverlayHides("the overlay didn't hide in full screen")
        hoverCanvas(0.4, 0.2)
        XCTAssertTrue(overlayCard.waitForExistence(timeout: 3), "the overlay didn't come back in full screen")
        roadie.app.typeKey(.escape, modifierFlags: [])
        expectFullScreen(false)
    }

    func testOverlayStaysUpWhilePaused() {
        openPlaying()
        roadie.app.typeKey("c", modifierFlags: [])
        XCTAssertTrue(roadie.wait { self.roadie.probe?.state == "paused" }, roadie.probeJSON)
        hoverCanvas()
        XCTAssertTrue(overlayCard.waitForExistence(timeout: 5), "no \(AXID.Vis.overlay): \(roadie.probeJSON)")
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(overlayCard.exists, "the overlay hid while paused")
        XCTAssertEqual(vis.probe?.overlay, "shown", roadie.probeJSON)
        XCTAssertEqual(roadie.element(AXID.Vis.Overlay.state).label, "Paused")
    }

    func testSpeakerPlaybackExplainsTheIdlePicture() {
        launch(library: .none, scenario: "playingOnSpeaker", windows: [.main], extra: Self.visArguments + Self.overlayIdle)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { (self.roadie.probe?.output ?? "thisMac") != "thisMac" },
            "the speaker wasn't adopted: \(roadie.probeJSON)")
        vis.open()
        XCTAssertTrue(vis.window.waitForExistence(timeout: 5), "vis.window never appeared")
        XCTAssertTrue(roadie.wait { self.vis.probe?.audio == "remote" }, roadie.probeJSON)
        hoverCanvas()
        let note = roadie.element(AXID.Vis.Overlay.note)
        XCTAssertTrue(note.waitForExistence(timeout: 5), "no \(AXID.Vis.Overlay.note): \(roadie.probeJSON)")
        XCTAssertTrue(note.label.hasPrefix("Playing on "), "note: \(note.label)")
        expectOverlayHides("the overlay didn't hide")
        XCTAssertTrue(roadie.element(AXID.Vis.noAudioBadge).exists, "no \(AXID.Vis.noAudioBadge)")
    }

    // MARK: Preset list (#0240)

    /// L in the key window opens the list; the search field is clicked so the keys go to it.
    private func openList() -> XCUIElement {
        openKeyWindow()
        roadie.app.typeKey("l", modifierFlags: [])
        let browser = roadie.element(AXID.Vis.browser)
        XCTAssertTrue(browser.waitForExistence(timeout: 5), "no \(AXID.Vis.browser)")
        let search = roadie.element(AXID.Vis.browserSearch)
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no \(AXID.Vis.browserSearch)")
        search.click()
        return browser
    }

    private func row(_ index: Int) -> XCUIElement { roadie.element(AXID.Vis.browserRow(index)) }

    func testLOpensTheListAndReturnLoadsTheSelection() {
        let browser = openList()
        XCTAssertTrue(row(0).waitForExistence(timeout: 5), "no row 0")
        XCTAssertEqual(row(0).label, "Classic Spectrum")
        XCTAssertTrue(roadie.wait { self.roadie.value(of: self.row(0)) == "current" }, "row 0 value is \"\(roadie.value(of: row(0)))\", expected current")
        roadie.app.typeKey(.downArrow, modifierFlags: [])
        roadie.app.typeKey(.downArrow, modifierFlags: [])
        roadie.app.typeKey(.return, modifierFlags: [])
        expectPreset("Classic Spectrum and Scope")
        XCTAssertTrue(roadie.wait { !browser.exists }, "the list is still open")
    }

    func testTypingFiltersTheList() {
        let browser = openList()
        roadie.app.typeText("mirr")
        XCTAssertTrue(roadie.wait { self.row(0).exists && self.row(0).label == "Classic Mirror" && !self.row(1).exists },
                      "the list didn't narrow to Classic Mirror")
        roadie.app.typeKey(.return, modifierFlags: [])
        expectPreset("Classic Mirror")
        XCTAssertTrue(roadie.wait { !browser.exists }, "the list is still open")
    }

    func testEscapeClosesTheList() {
        let browser = openList()
        roadie.app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(roadie.wait { !browser.exists }, "the list is still open")
        XCTAssertEqual(vis.preset, "Classic Spectrum")
        XCTAssertEqual(vis.probe?.presetChanges, 0)
    }

    // MARK: Settings › Visualization (#0241)

    /// ⌥⌘K opens Settings on the Visualization tab.
    private func openVisualizationSettings(file: StaticString = #filePath, line: UInt = #line) {
        roadie.app.typeKey("k", modifierFlags: [.command, .option])
        XCTAssertTrue(
            roadie.element("vis.settings.interval").waitForExistence(timeout: 10),
            "Settings › Visualization didn't open", file: file, line: line)
    }

    /// Picks `title` from the pop-up button `id`.
    private func choose(_ title: String, in id: String, file: StaticString = #filePath, line: UInt = #line) {
        let popUp = roadie.element(id)
        XCTAssertTrue(popUp.waitForExistence(timeout: 5), "no \(id)", file: file, line: line)
        popUp.click()
        let item = roadie.app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "\(id) has no \(title)", file: file, line: line)
        item.click()
    }

    func testCommandOptionKOpensTheVisualizationTab() {
        launchPlain()
        openVisualizationSettings()
        XCTAssertTrue(roadie.element("vis.settings.order").exists, "no vis.settings.order")
    }

    func testSettingsChangeTheRunningVisualization() {
        launch(windows: [.main], extra: ["-RoadieVisRenderer", "classic", "-RoadieVisSeed", "1"])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        vis.open()
        XCTAssertTrue(vis.window.waitForExistence(timeout: 5), "vis.window never appeared")
        XCTAssertTrue(roadie.wait { self.vis.probe?.open == true }, "probe: \(roadie.probeJSON)")
        XCTAssertEqual(vis.probe?.order, "random")
        openVisualizationSettings()
        choose("In order", in: "vis.settings.order")
        XCTAssertTrue(roadie.wait { self.vis.probe?.order == "sequential" }, roadie.probeJSON)
        choose("Never", in: "vis.settings.idle")
        let idle = roadie.element("vis.settings.idle")
        XCTAssertTrue(roadie.wait { self.roadie.value(of: idle) == "Never" }, "idle: \(roadie.describe(idle))")
    }

    func testPresetsFolderAddsItsPresets() {
        let folder = (paths.data as NSString).appendingPathComponent("vis-presets-\(UUID().uuidString)")
        launchPlain(extra: ["-RoadieVisPresetsFolder", folder, "-RoadieVisSeedPresets", "2", "-RoadieVisSeed", "1"])
        openVisualizationSettings()
        let count = roadie.element("vis.settings.folderCount")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { count.exists && (self.roadie.value(of: count) == "2 presets found" || count.label == "2 presets found") },
            "folder count: \(roadie.describe(count))")
        roadie.app.typeKey("w", modifierFlags: .command)  // close Settings
        vis.open()
        expectOpen()
        vis.window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).click()
        roadie.app.typeKey("l", modifierFlags: [])
        let search = roadie.element(AXID.Vis.browserSearch)
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no \(AXID.Vis.browserSearch)")
        search.click()
        roadie.app.typeText("Seeded")
        XCTAssertTrue(
            roadie.wait { self.row(0).exists && self.row(0).label == "Seeded Preset 1" && self.row(1).label == "Seeded Preset 2" },
            "the list doesn't have the folder's presets")
        roadie.app.typeKey(.escape, modifierFlags: [])
    }

    func testOpenOnPlayOpensTheWindow() {
        launchPlain(extra: ["-visualization.openOnPlay", "YES", "-RoadieOpenFiles", paths.music])
        XCTAssertTrue(roadie.wait { (self.roadie.probe?.queue.count ?? 0) > 0 }, "no queue: \(roadie.probeJSON)")
        XCTAssertFalse(vis.window.exists, "vis.window open before playing")
        roadie.click(roadie.main.play)
        roadie.waitForPlaying()
        XCTAssertTrue(vis.window.waitForExistence(timeout: 5), "vis.window didn't open on play")
    }
}
