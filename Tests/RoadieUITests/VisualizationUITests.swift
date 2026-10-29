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
}
