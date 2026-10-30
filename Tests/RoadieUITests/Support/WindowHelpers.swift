import Foundation
import XCTest

/// Helpers for the main window and menu tests (#0202).
extension RoadieUITestCase {
    /// The fixture library's Tone Album, in order (`scripts/make-test-library.sh`).
    var toneAlbum: [String] {
        ["01 Tone A.mp3", "02 Tone B.mp3", "03 Tone C.m4a"].map { music("Tone Artist/Tone Album/\($0)") }
    }

    /// Launches with `files` queued (`-RoadieOpenFiles`, which loads them stopped at row 0), all three skinned windows
    /// open, presses play and waits for playback. `repeating` makes sure Repeat is on (⌃⌘R) so the 2.5 s tracks never run out.
    func launchPlaying(
        _ files: [String]? = nil, windows: Windows = [.main, .equalizer, .playlist], repeating: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let files = files ?? toneAlbum
        launch(windows: windows, openFiles: files)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared", file: file, line: line)
        startQueued(count: files.count, file: file, line: line)
        // Only when off: the runner can't empty the data directory (it's sandboxed read-only), so a retry restores the
        // first attempt's queue.json with Repeat already on, and ⌃⌘R would turn it off.
        if repeating, roadie.probe?.repeatAll != true {
            roadie.app.typeKey("r", modifierFlags: [.command, .control])
            XCTAssertTrue(
                roadie.wait { self.roadie.probe?.repeatAll == true }, "Repeat (⌃⌘R) didn't turn on; probe: \(roadie.probeJSON)",
                file: file, line: line)
        }
    }

    /// Waits for `-RoadieOpenFiles`' queue to load, presses play and waits for playback.
    func startQueued(count: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.roadie.probe?.queue.count == count },
            "the launch queue never loaded; probe: \(roadie.probeJSON)", file: file, line: line)
        roadie.click(roadie.main.play, file: file, line: line)
        roadie.waitForPlaying(file: file, line: line)
    }

    // MARK: Toggle state

    /// A skinned toggle's state from its accessibility value (`on`/`off`, `skinControl`); nil when XCUITest doesn't
    /// expose it. The model state is in the probe (`shuffle`, `repeatAll`, `alwaysOnTop`, …), which tests assert first.
    func toggleValue(_ id: String) -> Bool? {
        switch roadie.value(of: element(id)) {
        case "on": true
        case "off": false
        default: nil
        }
    }

    /// Waits for the probe to report `expected` for a toggle (`keyPath`), then checks the skinned control `id` agrees
    /// when its value is readable.
    func expectToggle(
        _ id: String, _ keyPath: KeyPath<ProbeState, Bool?>, _ expected: Bool, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            roadie.wait { self.roadie.probe?[keyPath: keyPath] == expected },
            "\(what): model isn't \(expected ? "on" : "off"); probe: \(roadie.probeJSON)", file: file, line: line)
        if let shown = toggleValue(id) {
            XCTAssertTrue(
                roadie.wait { self.toggleValue(id) == expected },
                "\(what): \(id) shows \(shown ? "on" : "off"): \(roadie.describe(element(id)))", file: file, line: line)
        }
    }

    /// Whether a menu item shows a check mark, from what XCUITest exposes: `isSelected`, or a value that is a check
    /// mark or 0/1. nil when neither says (then the caller relies on the probe; the item's snapshot is attached so a
    /// run shows what is exposed).
    func checkMark(_ item: XCUIElement) -> Bool? {
        guard item.exists else { return nil }
        if item.isSelected { return true }
        switch item.value {
        case let text as String where ["✓", "✔", "on", "1"].contains(text): return true
        case let text as String where ["off", "0"].contains(text): return false
        case let number as NSNumber: return number.boolValue
        default: break
        }
        let attachment = XCTAttachment(string: item.debugDescription)
        attachment.name = "menu item \(item.title) (no check mark exposed)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return nil
    }

    /// Checks a menu item's check mark against `expected` when XCUITest exposes it (`checkMark`).
    func expectCheckMark(
        _ item: XCUIElement, _ expected: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let checked = checkMark(item) else { return }
        XCTAssertEqual(checked, expected, "\(what) check mark", file: file, line: line)
    }

    /// Opens `menu` in the menu bar, checks `title`'s check mark against `expected` (`expectCheckMark`), closes it.
    func expectMenuBarCheckMark(
        _ menu: String, _ title: String, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        let bar = roadie.app.menuBars.menuBarItems[menu]
        bar.click()
        let item = bar.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(menu) › \(title) missing", file: file, line: line)
        expectCheckMark(item, expected, "\(menu) › \(title)", file: file, line: line)
        closeMenus()
    }

    // MARK: Sliders

    /// A main-window slider's geometry in skin pixels (SkinKit's `MainSliders`, which this target doesn't link).
    struct MainSlider {
        var x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, thumbWidth: CGFloat, travel: CGFloat

        static let volume = MainSlider(x: 107, y: 57, width: 68, height: 13, thumbWidth: 14, travel: 51)
        static let balance = MainSlider(x: 177, y: 57, width: 38, height: 13, thumbWidth: 14, travel: 24)
        static let position = MainSlider(x: 16, y: 72, width: 248, height: 10, thumbWidth: 29, travel: 219)
    }

    /// Moves a main-window slider to `fraction` (0...1) with a pointer press and release where the thumb's centre
    /// lands at that fraction (`MainSliders.fraction(forPointerX:)`). `adjust(toNormalizedSliderPosition:)` can't be
    /// used: the accessibility Slider has no AXOrientation ("Unable to get expected orientation attribute", #0202).
    /// The window's width over its 275 skin pixels gives the scale, so double size works too.
    func setSlider(_ slider: MainSlider, to fraction: Double) {
        let window = mainWindow
        let scale = window.frame.width / 275
        let x = (slider.x + slider.thumbWidth / 2 + CGFloat(fraction) * slider.travel) * scale
        let y = (slider.y + slider.height / 2) * scale
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let target = origin.withOffset(CGVector(dx: x, dy: y))
        origin.withOffset(CGVector(dx: x - 1, dy: y)).press(forDuration: 0.1, thenDragTo: target)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    func element(_ id: String) -> XCUIElement { roadie.element(id) }

    /// The window holding the element with `id`.
    func window(containing id: String) -> XCUIElement {
        roadie.app.windows.containing(.any, identifier: id).firstMatch
    }

    var mainWindow: XCUIElement { window(containing: AXID.Main.marquee) }
    var eqWindow: XCUIElement { window(containing: AXID.EQ.on) }
    var playlistWindow: XCUIElement { window(containing: AXID.PL.scrollbar) }

    /// Clicks `window`'s title strip (a drag area in a skinned window) at `dx` of its width, making it key.
    func clickTitleStrip(_ window: XCUIElement, dx: CGFloat = 0.5) {
        let frame = window.frame
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width * dx, dy: 6)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Makes the main window key (its title buttons draw only then).
    func focusMain(file: StaticString = #filePath, line: UInt = #line) {
        clickTitleStrip(mainWindow, dx: 0.4)
        XCTAssertTrue(
            element(AXID.Main.Title.menu).waitForExistence(timeout: 5), "main window never became key (no main.title.menu)",
            file: file, line: line)
    }

    var state: String { roadie.probe?.state ?? "" }

    @discardableResult
    func expectState(_ expected: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = roadie.wait(timeout: timeout) { self.state == expected }
        XCTAssertTrue(ok, "state isn't \(expected); probe: \(roadie.probeJSON)", file: file, line: line)
        return ok
    }

    func expectPanelRequest(_ request: String, file: StaticString = #filePath, line: UInt = #line) {
        let ok = roadie.wait { self.roadie.probe?.panelRequests?.contains(request) == true }
        XCTAssertTrue(ok, "no panel request \"\(request)\"; probe: \(roadie.probeJSON)", file: file, line: line)
    }

    /// `main.time`'s value, e.g. `elapsed 00:01`.
    var timeValue: String { roadie.value(of: element(AXID.Main.time)) }

    /// A slider's value in percent.
    func percent(_ id: String) -> Int? { Int(roadie.value(of: element(id))) }

    /// The skinned pop-up menu (the only menu with Exit).
    var popUpMenu: XCUIElement {
        roadie.app.menus.containing(NSPredicate(format: "title == 'Exit'")).firstMatch
    }

    /// Opens the main window's pop-up menu from the title bar's menu button.
    @discardableResult
    func openPopUpMenu(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        focusMain(file: file, line: line)
        roadie.click(element(AXID.Main.Title.menu), file: file, line: line)
        let menu = popUpMenu
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the pop-up menu never opened", file: file, line: line)
        return menu
    }

    func closeMenus() {
        roadie.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Clicks a menu bar item's menu, then its item `title`.
    func clickMenuBar(_ menu: String, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = roadie.app.menuBars.menuBarItems[menu]
        bar.click()
        let item = bar.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(menu) › \(title) missing", file: file, line: line)
        item.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// `open -b co.sstools.roadie` while it runs: the Dock's reopen (`applicationShouldHandleReopen`).
    func reopenFromLaunchServices() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", "co.sstools.roadie"]
        if (try? open.run()) != nil { open.waitUntilExit() }
    }

    func assertClose(_ a: CGFloat, _ b: CGFloat, _ what: String, tolerance: CGFloat = 1.5,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a - b), tolerance, "\(what): \(a) vs \(b)", file: file, line: line)
    }

    /// Whether `below`'s top edge sits on `above`'s bottom edge, left edges aligned (docked).
    func isDocked(_ below: XCUIElement, under above: XCUIElement) -> Bool {
        let a = above.frame, b = below.frame
        return abs(b.minY - a.maxY) <= 1.5 && abs(b.minX - a.minX) <= 1.5
    }
}
