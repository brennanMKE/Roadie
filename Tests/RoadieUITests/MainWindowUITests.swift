import XCTest

/// The main window: transport, sliders, toggles, displays, clutter bar, title bar, shade, the skinned pop-up menu,
/// the bare Winamp keys and docking (#0202, design §5.2–§5.3). Folder library, base skin, tracks opened with
/// `-RoadieOpenFiles`. The fixture tracks are 2.5 s and auto-advance, so rows are read from the probe, not assumed.
final class MainWindowUITests: RoadieUITestCase {
    // MARK: Transport

    func testTransportButtons() {
        launchPlaying()
        roadie.click(element(AXID.Main.pause))
        expectState("paused")
        let paused = timeValue
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(timeValue, paused, "main.time moved while paused")
        roadie.click(element(AXID.Main.play))
        expectState("playing")
        roadie.click(element(AXID.Main.stop))
        expectState("stopped")
        XCTAssertTrue(
            roadie.waitForValue(element(AXID.Main.time)) { !$0.contains(where: { ("1"..."9").contains($0) }) },
            "main.time after stop: \(timeValue)")

        // Stopped on row k: next plays k+1 (Repeat on, so row 2 wraps to 0).
        guard let k = roadie.probe?.currentIndex else { return XCTFail("no current row; probe: \(roadie.probeJSON)") }
        roadie.click(element(AXID.Main.next))
        roadie.expectCurrentRow((k + 1) % 3)
        expectState("playing")
        // Previous from a stopped row j > 0 plays j-1.
        var j = roadie.stopPlayback() ?? 0
        if j == 0 {
            roadie.click(element(AXID.Main.next))
            j = roadie.stopPlayback() ?? 0
        }
        XCTAssertGreaterThan(j, 0, "probe: \(roadie.probeJSON)")
        roadie.click(element(AXID.Main.previous))
        roadie.expectCurrentRow(j - 1)

        roadie.click(element(AXID.Main.eject))
        expectPanelRequest("openFiles replace=true")
    }

    func testSeekAndTimeMode() {
        launchPlaying()
        roadie.app.typeKey("c", modifierFlags: [.command, .control])
        expectState("paused")
        setSlider(.position, to: 0.5)
        XCTAssertTrue(
            roadie.wait { (40...60).contains(self.percent(AXID.Main.position) ?? -1) },
            "main.position after seeking to 50 %: \(roadie.describe(element(AXID.Main.position)))")

        XCTAssertTrue(timeValue.hasPrefix("elapsed"), "time \(timeValue)")
        roadie.click(element(AXID.Main.time))
        XCTAssertTrue(roadie.waitForValue(element(AXID.Main.time)) { $0.hasPrefix("remaining") }, "time \(timeValue)")
        XCTAssertTrue(roadie.wait { self.roadie.probe?.timeMode == "remaining" }, "probe: \(roadie.probeJSON)")
        roadie.click(element(AXID.Main.time))
        XCTAssertTrue(roadie.waitForValue(element(AXID.Main.time)) { $0.hasPrefix("elapsed") }, "time \(timeValue)")
        XCTAssertTrue(roadie.wait { self.roadie.probe?.timeMode == "elapsed" }, "probe: \(roadie.probeJSON)")
    }

    func testVolumeAndBalance() {
        launchPlaying()
        // The pointer lands to the nearest point and the thumb's pixel rounds, so allow a few percent either way
        // (run 20261025-000141-54801 missed an exact 28...32 window; the value read is in the message).
        setSlider(.volume, to: 0.3)
        XCTAssertTrue(
            roadie.wait { (22...38).contains(self.percent(AXID.Main.volume) ?? -1) },
            "main.volume \(percent(AXID.Main.volume).map(String.init) ?? "unreadable") after a press at 30 %: "
                + roadie.describe(element(AXID.Main.volume)))
        // The balance slider's AXValue is its position: 0.75 is 50 % right.
        setSlider(.balance, to: 0.75)
        XCTAssertTrue(
            roadie.wait { (65...85).contains(self.percent(AXID.Main.balance) ?? -1) },
            "main.balance \(percent(AXID.Main.balance).map(String.init) ?? "unreadable") after a press at 75 %: "
                + roadie.describe(element(AXID.Main.balance)))
        // The release commits (endSliderDrag), so the marquee is back on the track.
        XCTAssertTrue(
            roadie.waitForValue(element(AXID.Main.marquee)) { $0.contains("Tone") && !$0.hasPrefix("Balance") },
            "marquee: \(roadie.value(of: element(AXID.Main.marquee)))")
    }

    func testShuffleRepeatToggles() {
        launchPlaying(repeating: false)
        roadie.click(element(AXID.Main.shuffle))
        expectToggle(AXID.Main.shuffle, \.shuffle, true, "main.shuffle click")
        expectMenuBarCheckMark("Playback", "Shuffle", true)
        roadie.app.typeKey("s", modifierFlags: [.command, .control])
        expectToggle(AXID.Main.shuffle, \.shuffle, false, "⌃⌘S")

        roadie.click(element(AXID.Main.repeatAll))
        expectToggle(AXID.Main.repeatAll, \.repeatAll, true, "main.repeat click")
        expectMenuBarCheckMark("Playback", "Repeat", true)
        roadie.app.typeKey("r", modifierFlags: [.command, .control])
        expectToggle(AXID.Main.repeatAll, \.repeatAll, false, "⌃⌘R")
    }

    func testEqAndPlaylistToggles() {
        launchPlaying()
        XCTAssertTrue(roadie.wait { self.isDocked(self.eqWindow, under: self.mainWindow) }, "EQ not docked at launch")
        let windows = roadie.app.windows.count

        roadie.click(element(AXID.Main.eq))
        XCTAssertTrue(roadie.wait { !self.element(AXID.EQ.on).exists }, "main.eq didn't close the equalizer")
        XCTAssertEqual(roadie.app.windows.count, windows - 1)
        roadie.click(element(AXID.Main.eq))
        XCTAssertTrue(element(AXID.EQ.on).waitForExistence(timeout: 5), "main.eq didn't reopen the equalizer")
        XCTAssertTrue(
            roadie.wait { self.isDocked(self.eqWindow, under: self.mainWindow) },
            "EQ \(eqWindow.frame) not docked under main \(mainWindow.frame)")

        roadie.click(element(AXID.Main.playlist))
        XCTAssertTrue(roadie.wait { !self.element(AXID.PL.scrollbar).exists }, "main.playlist didn't close the playlist")
        roadie.click(element(AXID.Main.playlist))
        XCTAssertTrue(element(AXID.PL.scrollbar).waitForExistence(timeout: 5), "main.playlist didn't reopen the playlist")
        XCTAssertTrue(
            roadie.wait { self.isDocked(self.playlistWindow, under: self.eqWindow) },
            "playlist \(playlistWindow.frame) not docked under EQ \(eqWindow.frame)")

        roadie.app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(roadie.wait { !self.element(AXID.EQ.on).exists }, "⌘2 didn't close the equalizer")
        roadie.app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(element(AXID.EQ.on).waitForExistence(timeout: 5), "⌘2 didn't reopen the equalizer")
        roadie.app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(roadie.wait { !self.element(AXID.PL.scrollbar).exists }, "⌘3 didn't close the playlist")
        roadie.app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(element(AXID.PL.scrollbar).waitForExistence(timeout: 5), "⌘3 didn't reopen the playlist")
    }

    // MARK: Displays

    func testMarqueeShowsTheTrack() {
        launchPlaying(Array(toneAlbum.prefix(2)))
        let marquee = element(AXID.Main.marquee)
        // `N. Artist - Title (m:ss)`; with two 2.5 s tracks either may be current when read.
        let pattern = #"^[12]\. Tone Artist - Tone [AB] \(\d+:\d{2}\)$"#
        XCTAssertTrue(
            roadie.waitForValue(marquee) { $0.range(of: pattern, options: .regularExpression) != nil },
            "marquee \"\(roadie.value(of: marquee))\"")
        guard let k = roadie.stopPlayback() else { return }
        let n = k + 1
        XCTAssertTrue(
            roadie.waitForValue(marquee) { $0.hasPrefix("\(n). Tone Artist - Tone \(["A", "B"][k])") },
            "stopped on row \(k): marquee \"\(roadie.value(of: marquee))\"")
        roadie.app.typeKey("b", modifierFlags: [.command, .control])
        let next = (k + 1) % 2
        XCTAssertTrue(
            roadie.waitForValue(marquee, timeout: 2) { $0.hasPrefix("\(next + 1). Tone Artist - Tone \(["A", "B"][next])") },
            "after next: marquee \"\(roadie.value(of: marquee))\"")
    }

    func testFormatIndicators() {
        launchPlaying([toneAlbum[0], music("Tone Artist/Two Discs/Disc 2/06 Tone F.wav")])
        guard let k = roadie.stopPlayback() else { return }
        if k != 0 { roadie.app.typeKey("b", modifierFlags: [.command, .control]) }
        roadie.expectCurrentRow(0)
        roadie.app.typeKey("c", modifierFlags: [.command, .control])
        let kbps = element(AXID.Main.kbps), khz = element(AXID.Main.khz), stereo = element(AXID.Main.stereo)
        XCTAssertTrue(roadie.waitForValue(kbps) { $0 == "64" }, "MP3 kbps: \(roadie.describe(kbps))")
        XCTAssertTrue(roadie.waitForValue(khz) { $0 == "44" }, "MP3 kHz: \(roadie.describe(khz))")
        XCTAssertTrue(roadie.waitForValue(stereo) { $0 == "stereo" || $0 == "mono" }, "channels: \(roadie.describe(stereo))")

        roadie.app.typeKey("b", modifierFlags: [.command, .control])
        roadie.expectCurrentRow(1)
        roadie.app.typeKey("c", modifierFlags: [.command, .control])
        // 1411 kbps doesn't fit three digits: Winamp shows hundreds as H, so 14H.
        XCTAssertTrue(roadie.waitForValue(kbps) { $0 == "14H" }, "WAV kbps: \(roadie.describe(kbps))")
    }

    func testVisualizerMenu() {
        launchPlaying()
        let visualizer = element(AXID.Main.visualizer)
        roadie.click(element(AXID.Main.Clutter.v))
        let oscilloscope = roadie.app.menuItems["Oscilloscope"]
        XCTAssertTrue(oscilloscope.waitForExistence(timeout: 5), "the visualizer menu never opened")
        oscilloscope.click()
        XCTAssertTrue(roadie.waitForValue(visualizer) { $0 == "oscilloscope" }, "visualizer: \(roadie.describe(visualizer))")
        roadie.click(element(AXID.Main.Clutter.v))
        let off = roadie.app.menuItems["Off"]
        XCTAssertTrue(off.waitForExistence(timeout: 5), "the visualizer menu never opened again")
        off.click()
        XCTAssertTrue(roadie.waitForValue(visualizer) { $0 == "off" }, "visualizer: \(roadie.describe(visualizer))")
    }

    // MARK: Clutter bar, title bar, shade

    func testClutterBar() {
        launchPlaying()
        roadie.click(element(AXID.Main.Clutter.a))
        expectToggle(AXID.Main.Clutter.a, \.alwaysOnTop, true, "A")
        expectMenuBarCheckMark("Window", "Always on Top", true)
        roadie.click(element(AXID.Main.Clutter.a))
        XCTAssertTrue(roadie.wait { self.roadie.probe?.alwaysOnTop == false }, "A again: probe \(roadie.probeJSON)")

        let normal = mainWindow.frame
        roadie.click(element(AXID.Main.Clutter.d))
        XCTAssertTrue(
            roadie.wait { abs(self.mainWindow.frame.width - normal.width * 2) <= 2 },
            "D: main \(mainWindow.frame), was \(normal)")
        roadie.click(element(AXID.Main.Clutter.d))
        XCTAssertTrue(roadie.wait { abs(self.mainWindow.frame.width - normal.width) <= 2 }, "D again: \(mainWindow.frame)")

        roadie.click(element(AXID.Main.Clutter.i))
        let info = roadie.app.windows["File Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5), "I didn't open File Info")
        info.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(roadie.wait { !info.exists }, "File Info didn't close")

        roadie.click(element(AXID.Main.Clutter.o))
        XCTAssertTrue(popUpMenu.waitForExistence(timeout: 5), "O didn't open the options menu")
        closeMenus()
    }

    func testTitleBar() {
        launchPlaying()
        focusMain()
        let normalHeight = mainWindow.frame.height
        // 116 skin px tall unshaded, 14 shaded, at the window's scale (2x in the guest).
        let scale = normalHeight / 116
        roadie.click(element(AXID.Main.Title.shade))
        XCTAssertTrue(element(AXID.Shade.Main.play).waitForExistence(timeout: 5), "shade.main.play missing after shade")
        // Shaded, main.marquee is gone, so the window is found by a shade control.
        let shaded = window(containing: AXID.Shade.Main.play)
        XCTAssertTrue(roadie.wait { abs(shaded.frame.height - 14 * scale) <= 1 }, "shaded main: \(shaded.frame)")
        // Double-click the shaded title (left of the time and transport) to unshade.
        shaded.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 7)).doubleClick()
        XCTAssertTrue(element(AXID.Main.play).waitForExistence(timeout: 5), "double-click didn't unshade")
        XCTAssertTrue(roadie.wait { abs(self.mainWindow.frame.height - normalHeight) <= 1 }, "main: \(mainWindow.frame)")

        focusMain()
        roadie.click(element(AXID.Main.Title.minimize))
        XCTAssertTrue(roadie.wait { !self.element(AXID.Main.play).isHittable }, "main.title.minimize left it on screen")
        reopenFromLaunchServices()
        XCTAssertTrue(roadie.wait(timeout: 10) { self.element(AXID.Main.play).isHittable }, "reopen didn't bring main back")

        // Close hides the main window; the app keeps running (no quit on last window), and reopen brings it back.
        focusMain()
        roadie.click(element(AXID.Main.Title.close))
        XCTAssertTrue(roadie.wait { !self.element(AXID.Main.play).exists }, "main.title.close left the window")
        XCTAssertNotEqual(roadie.app.state, .notRunning, "closing the main window quit the app")
        reopenFromLaunchServices()
        XCTAssertTrue(element(AXID.Main.play).waitForExistence(timeout: 10), "reopen didn't bring the closed main back")
    }

    func testShadeMode() {
        launchPlaying()
        roadie.app.typeKey("w", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.Shade.Main.pause).waitForExistence(timeout: 5), "⌃⌘W didn't shade the main window")
        roadie.click(element(AXID.Shade.Main.pause))
        expectState("paused")
        roadie.click(element(AXID.Shade.Main.play))
        expectState("playing")
        let time = element(AXID.Shade.Main.time)
        let first = roadie.value(of: time)
        XCTAssertTrue(roadie.waitForValue(time, timeout: 3) { $0 != first }, "shade.main.time stayed \"\(first)\"")
        roadie.click(element(AXID.Shade.Main.stop))
        expectState("stopped")
        roadie.app.typeKey("w", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.Main.play).waitForExistence(timeout: 5), "⌃⌘W didn't unshade")
    }

    func testAlwaysOnTopAndDoubleSize() {
        launch(windows: [.main, .equalizer, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        clickMenuBar("Window", "Always on Top")
        clickMenuBar("Window", "Double Size")
        XCTAssertTrue(
            roadie.wait { self.roadie.probe?.alwaysOnTop == true && self.roadie.probe?.doubleSize == true },
            "probe: \(roadie.probeJSON)")
        roadie.terminate()
        launch(windows: [.main, .equalizer, .playlist], keepingDefaults: true)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        XCTAssertTrue(
            roadie.wait { self.roadie.probe?.alwaysOnTop == true && self.roadie.probe?.doubleSize == true },
            "after relaunch: probe \(roadie.probeJSON)")
    }

    func testDragDocksTheEqualizer() {
        launch(windows: [.main, .equalizer, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        XCTAssertTrue(roadie.wait { self.isDocked(self.eqWindow, under: self.mainWindow) }, "EQ not docked at launch")
        // A small drag ends within the snap distance of main's bottom edge: it snaps back docked.
        drag(eqWindow, by: CGVector(dx: 8, dy: 8))
        XCTAssertTrue(
            roadie.wait { self.isDocked(self.eqWindow, under: self.mainWindow) },
            "EQ \(eqWindow.frame) didn't snap under main \(mainWindow.frame)")
        drag(eqWindow, by: CGVector(dx: 300, dy: 300))
        XCTAssertTrue(
            roadie.wait { self.eqWindow.frame.minY - self.mainWindow.frame.maxY > 100 },
            "EQ \(eqWindow.frame) didn't stay away from main \(mainWindow.frame)")
    }

    private func drag(_ window: XCUIElement, by offset: CGVector) {
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.frame.width * 0.5, dy: 6))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(offset))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    // MARK: The pop-up menu

    /// The top level of `MainMenu.entries`, without separators (SkinKit's `MainMenuTests` checks the order).
    private let popUpTitles = [
        "About Roadie", "Check for Updates…", "Play File…", "Add to Playlist…", "Equalizer", "Playlist Editor",
        "Media Library", "Skins", "Options", "Playback", "Visualization", "Exit",
    ]

    func testPopUpMenuOpens() {
        launch(windows: [.main, .equalizer, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        let menu = openPopUpMenu()
        for title in popUpTitles {
            XCTAssertTrue(menu.menuItems[title].exists, "pop-up item \(title)")
        }
        closeMenus()
        XCTAssertTrue(roadie.wait { !self.popUpMenu.exists }, "Esc left the pop-up open")

        // A right-click anywhere on the main window opens the same menu.
        mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(popUpMenu.waitForExistence(timeout: 5), "right-click didn't open the pop-up")
        XCTAssertTrue(popUpMenu.menuItems["Exit"].exists)
        closeMenus()
    }

    func testPopUpMenuItems() {
        launch(windows: [.main, .equalizer, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        let menu = openPopUpMenu()
        XCTAssertTrue(menu.menuItems["About Roadie"].isEnabled)
        XCTAssertFalse(menu.menuItems["Check for Updates…"].isEnabled, "Check for Updates… enabled in Debug")
        XCTAssertTrue(menu.menuItems["Play File…"].isEnabled)
        XCTAssertTrue(menu.menuItems["Add to Playlist…"].isEnabled)
        menu.menuItems["Play File…"].click()
        expectPanelRequest("openFiles replace=true")
        openPopUpMenu().menuItems["Add to Playlist…"].click()
        expectPanelRequest("openFiles replace=false")
    }

    func testPopUpTogglesWindows() {
        launch(windows: [.main, .equalizer, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        var menu = openPopUpMenu()
        expectCheckMark(menu.menuItems["Equalizer"], true, "pop-up Equalizer while open")
        expectCheckMark(menu.menuItems["Playlist Editor"], true, "pop-up Playlist Editor while open")
        menu.menuItems["Equalizer"].click()
        XCTAssertTrue(roadie.wait { !self.element(AXID.EQ.on).exists }, "pop-up Equalizer didn't close it")
        menu = openPopUpMenu()
        expectCheckMark(menu.menuItems["Equalizer"], false, "pop-up Equalizer while closed")
        menu.menuItems["Equalizer"].click()
        XCTAssertTrue(element(AXID.EQ.on).waitForExistence(timeout: 5), "pop-up Equalizer didn't reopen it")

        openPopUpMenu().menuItems["Playlist Editor"].click()
        XCTAssertTrue(roadie.wait { !self.element(AXID.PL.scrollbar).exists }, "pop-up Playlist Editor didn't close it")
        openPopUpMenu().menuItems["Playlist Editor"].click()
        XCTAssertTrue(element(AXID.PL.scrollbar).waitForExistence(timeout: 5), "pop-up Playlist Editor didn't reopen it")
    }

    func testOptionsSubmenu() {
        launch(windows: [.main, .equalizer, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        let titles = [
            "Time Elapsed", "Time Remaining", "Always On Top", "Double Size", "Windowshade", "EQ Windowshade",
            "Playlist Windowshade", "Repeat", "Shuffle",
        ]
        var menu = openPopUpMenu()
        menu.menuItems["Options"].hover()
        for title in titles {
            XCTAssertTrue(menu.menuItems[title].waitForExistence(timeout: 2), "Options › \(title)")
        }
        XCTAssertEqual(roadie.probe?.timeMode, "elapsed", "probe: \(roadie.probeJSON)")
        expectCheckMark(menu.menuItems["Time Elapsed"], true, "Options › Time Elapsed")
        menu.menuItems["Double Size"].click()
        XCTAssertTrue(roadie.wait { self.roadie.probe?.doubleSize == true }, "Double Size: probe \(roadie.probeJSON)")
        menu = openPopUpMenu()
        menu.menuItems["Options"].hover()
        XCTAssertTrue(menu.menuItems["Double Size"].waitForExistence(timeout: 2))
        expectCheckMark(menu.menuItems["Double Size"], true, "Options › Double Size while on")
        menu.menuItems["Double Size"].click()
        XCTAssertTrue(roadie.wait { self.roadie.probe?.doubleSize == false }, "Double Size off: probe \(roadie.probeJSON)")

        menu = openPopUpMenu()
        menu.menuItems["Options"].hover()
        XCTAssertTrue(menu.menuItems["Time Remaining"].waitForExistence(timeout: 2))
        menu.menuItems["Time Remaining"].click()
        XCTAssertTrue(roadie.waitForValue(element(AXID.Main.time)) { $0.hasPrefix("remaining") }, "time \(timeValue)")
        XCTAssertTrue(roadie.wait { self.roadie.probe?.timeMode == "remaining" }, "probe: \(roadie.probeJSON)")
    }

    func testPlaybackSubmenu() {
        launchPlaying()
        var menu = openPopUpMenu()
        menu.menuItems["Playback"].hover()
        for title in ["Previous", "Play", "Pause", "Stop", "Next", "Jump to File\u{2026}"] {
            XCTAssertTrue(menu.menuItems[title].waitForExistence(timeout: 2), "Playback › \(title)")
        }
        menu.menuItems["Stop"].click()
        expectState("stopped")
        guard let k = roadie.probe?.currentIndex else { return XCTFail("no current row; probe: \(roadie.probeJSON)") }
        menu = openPopUpMenu()
        menu.menuItems["Playback"].hover()
        XCTAssertTrue(menu.menuItems["Next"].waitForExistence(timeout: 2))
        menu.menuItems["Next"].click()
        roadie.expectCurrentRow((k + 1) % 3)
    }

    // MARK: Keys

    func testBareHotkeys() {
        launchPlaying()
        focusMain()
        let app = roadie.app
        app.typeKey("c", modifierFlags: [])
        expectState("paused")
        app.typeKey("x", modifierFlags: [])
        expectState("playing")
        app.typeKey("v", modifierFlags: [])
        expectState("stopped")
        guard let k = roadie.probe?.currentIndex else { return XCTFail("no current row; probe: \(roadie.probeJSON)") }
        app.typeKey("b", modifierFlags: [])
        roadie.expectCurrentRow((k + 1) % 3)
        var j = roadie.stopPlayback() ?? 0
        if j == 0 {
            app.typeKey("b", modifierFlags: [])
            j = roadie.stopPlayback() ?? 0
        }
        focusMain()
        app.typeKey("z", modifierFlags: [])
        roadie.expectCurrentRow(j - 1)

        app.typeKey("s", modifierFlags: [])
        expectToggle(AXID.Main.shuffle, \.shuffle, true, "S")
        app.typeKey("s", modifierFlags: [])
        expectToggle(AXID.Main.shuffle, \.shuffle, false, "S again")
        app.typeKey("r", modifierFlags: [])
        expectToggle(AXID.Main.repeatAll, \.repeatAll, false, "R")
        app.typeKey("r", modifierFlags: [])
        expectToggle(AXID.Main.repeatAll, \.repeatAll, true, "R again")

        let volume = percent(AXID.Main.volume) ?? 50
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(roadie.wait { (self.percent(AXID.Main.volume) ?? 0) > volume }, "↑ didn't raise the volume")
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(roadie.wait { (self.percent(AXID.Main.volume) ?? 100) < volume }, "↓ didn't lower the volume")

        // ← seeks back 5 s: from the middle of a paused 2.5 s track, to its start.
        app.typeKey("x", modifierFlags: [])
        expectState("playing")
        app.typeKey("c", modifierFlags: [])
        expectState("paused")
        setSlider(.position, to: 0.6)
        XCTAssertTrue(roadie.wait { (self.percent(AXID.Main.position) ?? 0) >= 40 }, "seek to 60 % didn't take")
        focusMain()
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(roadie.wait { (self.percent(AXID.Main.position) ?? 100) <= 10 }, "← didn't seek back")

        app.typeKey("l", modifierFlags: [])
        expectPanelRequest("openFiles replace=true")
        focusMain()
        app.typeKey("j", modifierFlags: [])
        XCTAssertTrue(element(AXID.Jump.search).waitForExistence(timeout: 5), "J didn't open Jump to File")
        closeMenus()
        XCTAssertTrue(roadie.wait { !self.element(AXID.Jump.search).exists }, "Esc didn't close Jump to File")
    }

    // MARK: Notices and reopen

    func testMissingFileShowsANotice() {
        // The runner is sandboxed read-only outside its container, so the app stages the missing file: with
        // `-RoadieVanishingFile 1` it queues a copy of Tone B from its data directory and deletes the copy once queued.
        launch(
            windows: [.main, .equalizer, .playlist], openFiles: Array(toneAlbum.prefix(3)),
            extra: ["-RoadieVanishingFile", "1"])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        let copy = (dataDirectory as NSString).appendingPathComponent("Vanishing 02 Tone B.mp3")
        XCTAssertTrue(roadie.wait(timeout: 10) { !FileManager.default.fileExists(atPath: copy) }, "the app never deleted \(copy)")
        startQueued()

        let marquee = element(AXID.Main.marquee)
        XCTAssertTrue(
            roadie.waitForValue(marquee, timeout: 8) { $0.hasPrefix("Could not play") },
            "marquee \"\(roadie.value(of: marquee))\"; probe: \(roadie.probeJSON)")
        XCTAssertTrue(
            roadie.wait(timeout: 5) { self.roadie.probe?.currentIndex == 2 && self.state == "playing" },
            "playback didn't move on past the missing file; probe: \(roadie.probeJSON)")
    }

    func testReopenShowsWindows() {
        launch(windows: [.main, .equalizer, .playlist])
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10))
        clickTitleStrip(playlistWindow)
        let close = element(AXID.PL.titleClose)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "pl.title.close missing")
        roadie.click(close)
        XCTAssertTrue(roadie.wait { !self.element(AXID.PL.scrollbar).exists }, "the playlist didn't close")

        reopenFromLaunchServices()
        XCTAssertTrue(roadie.wait(timeout: 10) { self.element(AXID.Main.play).isHittable }, "reopen didn't show main")
        XCTAssertTrue(element(AXID.EQ.on).exists, "the open equalizer went away on reopen")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(element(AXID.PL.scrollbar).exists, "reopen brought back the closed playlist")
    }
}
