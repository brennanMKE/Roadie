import XCTest

/// The Skins window, the Skin Museum (fixture transport), the Skins menu and Settings › Skins (#0208, design §5.8).
/// Base skin; the library is `TestSkins/` (seven manifest skins). Run only in the Tart guest: scripts/verify.sh --ui.
final class SkinsUITests: RoadieUITestCase {
    private let manifestCount = TestSkin.allCases.count
    /// Points per skin pixel without Double Size (`PlayerModel.baseScale`).
    static let scale: CGFloat = 2

    // MARK: Library

    func testLibraryGrid() {
        launch()
        openSkinsWindow()
        waitForCells(manifestCount)
        let labels = Set(cells().map(\.label))
        XCTAssertEqual(labels, Set(TestSkin.allCases.map(\.rawValue)), "cell labels")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.staticText("\(self.manifestCount) skins").exists },
            "no \"\(manifestCount) skins\" count label")

        // The status filter: OK keeps some (not necessarily all: `base` lacks sheets), All brings back seven.
        pickFilter("OK")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { (1...self.manifestCount).contains(self.roadie.count("skins.cell")) },
            "OK filter shows \(roadie.count("skins.cell")) cells")
        pickFilter("All")
        waitForCells(manifestCount)

        clickCell(TestSkin.windowsClassic.rawValue)
        waitForSkin(TestSkin.windowsClassic.rawValue)
        XCTAssertEqual(
            mainWindow()?.frame.size, CGSize(width: 275 * Self.scale, height: 116 * Self.scale),
            "main window size: 275×116 skin pixels at the base scale")

        let random = roadie.element(AXID.Skins.random)
        var changed = false
        for _ in 0..<3 where !changed {
            roadie.click(random)
            changed = roadie.wait(timeout: 5) { self.roadie.probe?.skin != TestSkin.windowsClassic.rawValue }
        }
        XCTAssertTrue(changed, "Random never changed the skin; probe: \(roadie.probeJSON)")

        roadie.click(roadie.element(AXID.Skins.refresh))
        waitForCells(manifestCount)
    }

    func testNextPreviousRandom() {
        launch()
        waitForCountsInSkinsWindow()
        let start = TestSkin.base291.rawValue
        waitForSkin(start)
        roadie.app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(roadie.wait(timeout: 5) { self.roadie.probe?.skin != start }, "⌘] kept \(start)")
        let next = roadie.probe?.skin
        roadie.app.typeKey("[", modifierFlags: .command)
        waitForSkin(start)

        roadie.app.typeKey("r", modifierFlags: [.command, .shift])
        if !roadie.wait(timeout: 5, { self.roadie.probe?.skin != start }) {
            roadie.app.typeKey("r", modifierFlags: [.command, .shift])  // random may pick the same skin once
        }
        XCTAssertTrue(roadie.wait(timeout: 5) { self.roadie.probe?.skin != start }, "⇧⌘R kept \(start)")

        // The main window's pop-up: Skins ▸ Next Skin. Its button shows only on the key main window (Window › Player, ⌘1).
        roadie.app.typeKey("1", modifierFlags: .command)
        let before = roadie.probe?.skin
        if openPopUpItem(submenu: "Skins", item: "Next Skin") {
            XCTAssertTrue(
                roadie.wait(timeout: 5) { self.roadie.probe?.skin != before }, "pop-up Next Skin kept \(before ?? "nil")")
        }
        XCTAssertNotNil(next)

        // No skins folder: the menu bar's Skins navigation is disabled.
        roadie.terminate()
        launch(skinsFolder: .none)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
        let menu = roadie.app.menuBars.menuBarItems["Skins"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no Skins menu")
        menu.click()
        for title in ["Next Skin", "Previous Skin", "Random Skin"] {
            let item = menu.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "no \(title)")
            XCTAssertFalse(item.isEnabled, "\(title) enabled with no skins folder")
        }
        roadie.app.typeKey(.escape, modifierFlags: [])
    }

    func testOpenWszViaOpenCommand() {
        launch()
        waitForSkin(TestSkin.base291.rawValue)
        // Finder's path: Launch Services hands the running app the file (`application(_:open:)`).
        let file = (paths.skins as NSString).appendingPathComponent("\(TestSkin.pikaAmp.rawValue).wsz")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", "co.sstools.roadie", file]
        XCTAssertNoThrow(try open.run())
        open.waitUntilExit()
        XCTAssertEqual(open.terminationStatus, 0, "open -b co.sstools.roadie \(file)")
        waitForSkin(TestSkin.pikaAmp.rawValue, timeout: 15)
    }

    func testCellTrashMovesTheSkinOut() {
        launch(mutatesSkins: true)
        openSkinsWindow()
        waitForCells(manifestCount)
        let victim = TestSkin.windows98Amp.rawValue
        let cell = cells().first { $0.label == victim }
        guard let cell else { return XCTFail("no cell \(victim)") }
        cell.rightClick()
        let trash = roadie.app.menuItems["Move to Trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 3), "no Move to Trash in the cell's menu")
        trash.click()
        waitForCells(manifestCount - 1)
        // The sandboxed runner reads the skins folder through the probe.
        XCTAssertTrue(
            roadie.wait(timeout: 5) { self.roadie.probe?.skinFiles.map { !$0.contains("\(victim).wsz") } == true },
            "\(victim).wsz still in the skins folder; probe: \(roadie.probeJSON)")
    }

    // MARK: Museum

    /// The fixture page's first row is rewritten to Pika_Amp (`-RoadieMuseumFeatured`, #0208), which the library copy
    /// leaves out: Download adds a real, new skin.
    func testMuseumTab() {
        launch(mutatesSkins: true, withoutSkins: [.pikaAmp], museumFeatured: .pikaAmp)
        let libraryCount = manifestCount - 1
        openSkinsWindow()
        waitForCells(libraryCount)

        chooseSource("Museum")
        // skins-page1.json: "0psis01[1]" is a recorded row; "109babe[1]" is nsfw (hidden by default).
        let recorded = museumCell(md5: "aa0b1a")
        XCTAssertTrue(recorded.waitForExistence(timeout: 15), "fixture page never listed")
        XCTAssertFalse(museumCell(md5: "9355a7").exists, "NSFW row shown with the setting off")

        // Search: search-zelda.json's rows.
        let search = roadie.app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no Museum search field")
        search.click()
        search.typeText("zelda\r")
        XCTAssertTrue(museumCell(md5: "1f8214").waitForExistence(timeout: 10), "search-zelda rows never listed")
        XCTAssertFalse(recorded.exists, "page rows still listed after the search")
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        search.typeText("\r")

        // The featured row (Pika_Amp's md5): Download → Apply.
        let featured = roadie.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'skins.museum.cell.' AND label == %@", TestSkin.pikaAmp.rawValue)
        ).firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 15), "featured row never listed")
        let md5 = String(featured.identifier.dropFirst("skins.museum.cell.".count))
        let action = roadie.element("skins.museum.action.\(md5)")
        XCTAssertTrue(action.waitForExistence(timeout: 5), "no Download button")
        XCTAssertEqual(action.title.isEmpty ? action.label : action.title, "Download")
        roadie.click(action)
        XCTAssertTrue(
            roadie.wait(timeout: 15) { (action.title.isEmpty ? action.label : action.title) == "Apply" },
            "Download never became Apply: \(roadie.describe(action))")
        XCTAssertTrue(
            roadie.wait(timeout: 5) {
                self.roadie.probe?.skinFiles?.contains { $0.hasPrefix("Museum/") && $0.hasSuffix(".wsz") } == true
            },
            "nothing downloaded into the skins folder's Museum/; probe: \(roadie.probeJSON)")

        roadie.click(action)
        waitForSkin(TestSkin.pikaAmp.rawValue + "_[S0]")

        featured.rightClick()
        clickMenuItem("Open in Skin Museum")
        XCTAssertTrue(
            roadie.wait { self.roadie.probe?.lastExternalOpen == "https://skins.webamp.org/skin/\(md5)" },
            "Open in Skin Museum not recorded; probe: \(roadie.probeJSON)")
        featured.rightClick()
        clickMenuItem("Show in Finder")
        XCTAssertTrue(
            roadie.wait { self.roadie.probe?.lastExternalOpen?.hasPrefix("file://") == true },
            "Show in Finder not recorded; probe: \(roadie.probeJSON)")

        chooseSource("Library")
        waitForCells(libraryCount + 1)
        chooseSource("Museum")
        XCTAssertTrue(featured.waitForExistence(timeout: 10))
        featured.rightClick()
        clickMenuItem("Move to Trash")
        XCTAssertTrue(
            roadie.wait(timeout: 10) { (action.title.isEmpty ? action.label : action.title) == "Download" },
            "Move to Trash left the skin downloaded: \(roadie.describe(action))")
        chooseSource("Library")
        waitForCells(libraryCount)
    }

    func testNsfwToggle() {
        launch()
        openSkinsWindow()
        chooseSource("Museum")
        let safe = museumCell(md5: "aa0b1a")
        let nsfw = museumCell(md5: "9355a7")
        XCTAssertTrue(safe.waitForExistence(timeout: 15), "fixture page never listed")
        XCTAssertFalse(nsfw.exists, "NSFW row shown with the setting off")

        setNSFW(true)
        XCTAssertTrue(nsfw.waitForExistence(timeout: 10), "NSFW row hidden with the setting on")
        setNSFW(false)
        XCTAssertTrue(roadie.wait(timeout: 10) { !nsfw.exists }, "NSFW row still shown with the setting off")
    }

    func testNoSkinPlaceholder() {
        launch(windows: [.main, .equalizer, .playlist], loadsSkin: false)
        let browse = roadie.element("player.browseMuseum")
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "no placeholder Browse button")
        XCTAssertNil(roadie.probe?.skin, "a skin loaded without -lastSkinPath; probe: \(roadie.probeJSON)")
        XCTAssertGreaterThanOrEqual(
            roadie.app.buttons.matching(NSPredicate(format: "title == 'Open Skin…' OR label == 'Open Skin…'")).count, 3,
            "the main, EQ and playlist placeholders each show Open Skin…")
        roadie.click(browse)
        XCTAssertTrue(museumCell(md5: "aa0b1a").waitForExistence(timeout: 15), "Browse didn't open the Museum tab")
    }

    func testSettingsSkinsTab() {
        launch()
        openSettingsSkins()
        let folder = roadie.element("skins.folder")
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "no skins.folder")
        XCTAssertEqual(text(folder), paths.skins)
        let counts = roadie.element("skins.counts")
        let expected = "\(manifestCount) skins in \(manifestCount) files"
        XCTAssertTrue(roadie.wait(timeout: 30) { self.text(counts) == expected }, "counts \"\(text(counts))\"")

        roadie.click(roadie.element("skins.scan"))
        XCTAssertTrue(roadie.wait(timeout: 30) { self.isIdle && self.text(counts) == expected }, "Scan: \(text(counts))")

        roadie.click(button("Rescan All"))
        XCTAssertTrue(roadie.wait(timeout: 30) { self.isIdle && self.text(counts) == expected }, "Rescan: \(text(counts))")

        roadie.click(button("Reset Index…"))
        let reset = roadie.element("skins.reset")
        XCTAssertTrue(reset.waitForExistence(timeout: 3), "no Reset confirmation")
        roadie.click(reset)
        XCTAssertTrue(
            roadie.wait(timeout: 10) { self.text(counts) != expected }, "Reset left the counts at \(text(counts))")
        roadie.click(roadie.element("skins.scan"))
        XCTAssertTrue(roadie.wait(timeout: 30) { self.text(counts) == expected }, "rescan after reset: \(text(counts))")
    }

    // MARK: Helpers

    private func openSkinsWindow(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared", file: file, line: line)
        roadie.app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(
            roadie.element(AXID.Skins.source).waitForExistence(timeout: 10), "⌘K didn't open the Skins window",
            file: file, line: line)
        chooseSource("Library", file: file, line: line)  // the tab a caller wants starts from a known one
    }

    /// The menu commands need the index loaded: open the Skins window (it starts the index) and wait for 7 cells.
    private func waitForCountsInSkinsWindow() {
        openSkinsWindow()
        waitForCells(manifestCount)
    }

    private func cells() -> [XCUIElement] {
        roadie.app.descendants(matching: .any).matching(identifier: "skins.cell").allElementsBoundByIndex
    }

    private func waitForCells(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        let ok = roadie.wait(timeout: 30) { self.roadie.count("skins.cell") == n }
        XCTAssertTrue(ok, "\(roadie.count("skins.cell")) skins.cell, expected \(n)", file: file, line: line)
    }

    private func clickCell(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let cell = cells().first(where: { $0.label == name }) else {
            return XCTFail("no cell \(name)", file: file, line: line)
        }
        roadie.click(cell, file: file, line: line)
    }

    private func waitForSkin(_ name: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let ok = roadie.wait(timeout: timeout) { self.roadie.probe?.skin == name }
        XCTAssertTrue(ok, "skin isn't \(name); probe: \(roadie.probeJSON)", file: file, line: line)
    }

    private func mainWindow() -> XCUIElement? {
        roadie.app.windows.allElementsBoundByIndex.first {
            $0.descendants(matching: .any).matching(identifier: AXID.Main.play).count > 0
        }
    }

    private func museumCell(md5 prefix: String) -> XCUIElement {
        roadie.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "\(AXID.Skins.museumCell).\(prefix)")
        ).firstMatch
    }

    private func chooseSource(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = roadie.element(AXID.Skins.source)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no \(AXID.Skins.source)", file: file, line: line)
        let segment = picker.descendants(matching: .any).matching(
            NSPredicate(format: "(title == %@ OR label == %@) AND elementType != %d", title, title,
                XCUIElement.ElementType.staticText.rawValue)
        ).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 3), "no \(title) segment: \(roadie.describe(picker))", file: file, line: line)
        segment.click()
    }

    private func pickFilter(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let filter = roadie.element(AXID.Skins.filter)
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "no \(AXID.Skins.filter)", file: file, line: line)
        roadie.click(filter, file: file, line: line)
        clickMenuItem(title, file: file, line: line)
    }

    private func staticText(_ label: String) -> XCUIElement {
        roadie.app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).firstMatch
    }

    private func button(_ title: String) -> XCUIElement {
        roadie.app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
    }

    /// A SwiftUI `Text`'s string: its value, else its label.
    private func text(_ element: XCUIElement) -> String {
        let value = roadie.value(of: element)
        return value.isEmpty ? (element.exists ? element.label : "") : value
    }

    /// Settings › Skins shows Scan (not Cancel) when no pass runs.
    private var isIdle: Bool { roadie.element("skins.scan").exists }

    private func clickMenuItem(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = roadie.app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "no menu item \(title)", file: file, line: line)
        item.click()
    }

    private func openSettingsSkins(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared", file: file, line: line)
        roadie.app.typeKey(",", modifierFlags: .command)
        let tab = roadie.app.toolbars.buttons["Skins"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no Settings › Skins tab", file: file, line: line)
        tab.click()
    }

    private func setNSFW(_ on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        openSettingsSkins(file: file, line: line)
        let toggle = roadie.element("skins.museum.nsfw")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no skins.museum.nsfw", file: file, line: line)
        let isOn = { (self.roadie.value(of: toggle) == "1") }
        if isOn() != on { toggle.click() }
        XCTAssertTrue(roadie.wait { isOn() == on }, "NSFW toggle: \(roadie.describe(toggle))", file: file, line: line)
        roadie.app.typeKey("w", modifierFlags: .command)  // close Settings; the Skins window shows the change
    }

    /// Opens the main window's pop-up (`main.title.menu`) and picks `submenu` ▸ `item`. false (recorded as a
    /// failure) when a step is missing.
    private func openPopUpItem(submenu: String, item: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let button = roadie.element(AXID.Main.Title.menu)
        guard button.waitForExistence(timeout: 5) else {
            XCTFail("no \(AXID.Main.Title.menu)", file: file, line: line)
            return false
        }
        roadie.click(button, file: file, line: line)
        let popUp = roadie.main.popUpMenu
        let sub = popUp.menuItems[submenu]
        guard sub.waitForExistence(timeout: 3) else {
            XCTFail("pop-up has no \(submenu)", file: file, line: line)
            return false
        }
        sub.hover()
        let entry = sub.menuItems[item]
        guard entry.waitForExistence(timeout: 3) else {
            XCTFail("pop-up \(submenu) has no \(item)", file: file, line: line)
            return false
        }
        entry.click()
        return true
    }
}
