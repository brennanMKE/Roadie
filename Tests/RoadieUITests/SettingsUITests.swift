import XCTest

/// Settings' tabs (#0209; design docs/design/test-automation.md §5.9, the Updates rows of §5.1). Visualization's own
/// tests are in VisualizationUITests (#0241). Run only in the Tart guest: scripts/verify.sh --ui. Every launch uses test mode's own defaults suite and data directory.
final class SettingsUITests: RoadieUITestCase {
    private func launchReady(
        library: TestLibrary = .folder, scenario: String? = nil, keepingDefaults: Bool = false, extra: [String] = []
    ) {
        launch(library: library, scenario: scenario, keepingDefaults: keepingDefaults, extra: extra)
        XCTAssertTrue(roadie.main.play.waitForExistence(timeout: 10), "main.play never appeared")
    }

    /// Settings (⌘,), then the tab named `tab`; waits for `marker` (an identifier on that tab).
    private func openSettings(tab: String, marker: String, file: StaticString = #filePath, line: UInt = #line) {
        roadie.app.typeKey(",", modifierFlags: .command)
        selectTab(tab, marker: marker, file: file, line: line)
    }

    private func selectTab(_ tab: String, marker: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = roadie.app.toolbars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Settings has no \(tab) tab", file: file, line: line)
        button.click()
        XCTAssertTrue(
            roadie.element(marker).waitForExistence(timeout: 10), "the \(tab) tab never showed \(marker)", file: file,
            line: line)
    }

    /// An element's value and label together (SwiftUI puts a LabeledContent's text in either).
    private func text(_ id: String) -> String {
        let element = roadie.element(id)
        guard element.exists else { return "" }
        return roadie.value(of: element) + " " + element.label
    }

    /// Whether the Settings window shows `text` within `timeout` (label or value; `RoadieUIApp.textExists`).
    private func hasText(_ text: String, timeout: TimeInterval = 5) -> Bool {
        roadie.wait(timeout: timeout) { roadie.textExists(text, in: settingsWindow) }
    }

    /// A source radio button by its title. In a grouped Form each option is its own row, and `library.source` lands on
    /// the first row's group only (run 20261024-232753-36837: one RadioButton, "Library source, Music Assistant (not set
    /// up)"), so this searches the Settings window's radio buttons by label.
    private func sourceOption(_ title: String) -> XCUIElement {
        settingsWindow.radioButtons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private var settingsWindow: XCUIElement {
        roadie.app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
    }

    /// The server list's rows. A List row shows up as an outline row (or table row) holding a cell, so counting cells
    /// as well double-counted (run 20261024-232753-36837: Add's new row added two).
    private func serverRows(_ servers: XCUIElement) -> XCUIElementQuery {
        if servers.outlineRows.count > 0 { return servers.outlineRows }
        if servers.tableRows.count > 0 { return servers.tableRows }
        return servers.cells
    }

    /// Scrolls the Settings form until `element` is inside its visible area. Settings is a 450-pt window, so the
    /// Music Assistant tab's editor sits below the fold, and `RoadieUIApp.click`'s coordinate fallback then clicked
    /// outside the window (run 20261024-234816-47563: `ma.name` at y 1156, no keyboard focus). The scroll direction
    /// is checked after the first step and flipped if the element moved the wrong way.
    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 5) else {
            return XCTFail("no \(element) to scroll to", file: file, line: line)
        }
        let scroll = settingsWindow.scrollViews.firstMatch
        guard scroll.exists else { return }
        var sign: CGFloat = 1
        var previous = element.frame.midY
        for _ in 0..<20 {
            let visible = scroll.frame.insetBy(dx: 0, dy: 8)
            let mid = element.frame.midY
            if visible.contains(CGPoint(x: visible.midX, y: mid)) { return }
            // Below the visible area: bring content up; above: bring it down. One step covers the gap (60-pt steps
            // took up to 9 scrolls per element in run 20261025-000315-56017).
            let below = mid > visible.maxY
            let towards: CGFloat = below ? -1 : 1
            let gap = below ? mid - visible.maxY : visible.minY - mid
            scroll.scroll(byDeltaX: 0, deltaY: towards * sign * min(max(gap + visible.height / 2, 60), 600))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let moved = element.frame.midY - previous
            // Content should move opposite to the gap (an element below moves up, so its y shrinks).
            if moved != 0, (moved > 0) == (mid > visible.maxY) { sign = -sign }
            previous = element.frame.midY
        }
        XCTFail("couldn't scroll \(element.identifier) into the Settings window: \(roadie.describe(element))",
            file: file, line: line)
    }

    /// `reveal`, then click.
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(element, file: file, line: line)
        roadie.click(element, file: file, line: line)
    }

    /// Reveals and clicks a text field (which also makes the Settings window key), then replaces its text.
    private func replaceText(_ field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        reveal(field, file: file, line: line)
        roadie.click(field, file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func isOn(_ element: XCUIElement) -> Bool {
        let v = roadie.value(of: element)
        return v == "1" || element.isSelected
    }

    func testLibraryTab() {
        launchReady(extra: ["-RoadieChooseFolder", paths.music])
        openSettings(tab: "Library", marker: "library.source")
        let folder = sourceOption("Local Folder")
        var ma = sourceOption("Music Assistant")
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "the source picker lacks the folder: \(roadie.describe(settingsWindow))")
        XCTAssertTrue(ma.exists, "the source picker lacks Music Assistant")
        XCTAssertTrue(roadie.wait { isOn(folder) }, "the folder isn't the selected source: \(roadie.describe(folder))")
        XCTAssertTrue(text("library.folder").contains(paths.music), "library.folder: \(text("library.folder"))")

        let status = roadie.element("library.status")
        XCTAssertTrue(roadie.wait(timeout: 60) { text("library.status").contains("track") }, "never indexed: \(text("library.status"))")
        tap(roadie.element("library.reindex"))
        XCTAssertTrue(
            roadie.wait(timeout: 60) { text("library.status").contains("track") && roadie.element("library.reindex").isEnabled },
            "Reindex never finished: \(roadie.describe(status))")

        tap(roadie.element("library.clear"))
        XCTAssertTrue(
            roadie.wait { text("library.folder").contains("No folder chosen") }, "Clear left \(text("library.folder"))")
        XCTAssertFalse(roadie.element("library.reindex").isEnabled, "Reindex enabled with no folder")
        // Choose… (answered by -RoadieChooseFolder) sets the folder again and indexes it.
        tap(roadie.element("library.choose"))
        XCTAssertTrue(
            roadie.wait { text("library.folder").contains(paths.music) }, "Choose… left \(text("library.folder"))")
        XCTAssertTrue(
            roadie.wait(timeout: 60) { text("library.status").contains("track") },
            "Choose… never indexed: \(text("library.status"))")

        // Relaunch with the scripted server: switching the source to Music Assistant changes the Library's sidebar.
        roadie.terminate()
        launchReady(scenario: "libraryIdle")
        openSettings(tab: "Library", marker: "library.source")
        ma = sourceOption("Music Assistant")
        XCTAssertTrue(ma.waitForExistence(timeout: 5), "the source picker lacks Music Assistant")
        ma.click()
        XCTAssertTrue(roadie.wait { isOn(ma) }, "Music Assistant didn't become the source")
        roadie.app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(
            roadie.element(AXID.Library.sidebar("playlists")).waitForExistence(timeout: 20),
            "the Library's sidebar has no Playlists on Music Assistant")

        // An unreachable server: the source status and Retry Now show.
        roadie.terminate()
        launchReady(scenario: "unreachable")
        openSettings(tab: "Library", marker: "library.source")
        ma = sourceOption("Music Assistant")
        XCTAssertTrue(ma.waitForExistence(timeout: 5), "the source picker lacks Music Assistant")
        ma.click()
        XCTAssertTrue(roadie.wait { isOn(ma) }, "Music Assistant didn't become the source")
        // Choosing a source only activates it; the failure shows when the Library window connects (the fallback hears
        // the connect error, falls back to the folder and Settings shows why). Run 20261024-234816-47563 waited 30 s
        // with no Library open and nothing came.
        roadie.app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(
            roadie.element("library.sourceStatus").waitForExistence(timeout: 15),
            "no library.sourceStatus with Music Assistant unreachable; source: \(roadie.describe(settingsWindow))")
        XCTAssertTrue(roadie.element("library.sourceRetry").exists, "no Retry Now with Music Assistant unreachable")

        // No server configured, Music Assistant preferred: the Library offers Find Servers on This Network. Bonjour is
        // off (-RoadieNoDiscovery), but the well-known host homeassistant.local is still probed, through the stub
        // transport that answers `/info` for any host, so the search finds one server to add.
        roadie.terminate()
        launchReady(library: .none, extra: ["-LibrarySource", "musicAssistant"])
        roadie.app.typeKey("l", modifierFlags: .command)
        let find = roadie.element("library.findServers")
        XCTAssertTrue(find.waitForExistence(timeout: 15), "no Find Servers with no Music Assistant server")
        roadie.click(find)
        XCTAssertTrue(
            roadie.element("ma.discovered.add").waitForExistence(timeout: 15),
            "Find Servers offered nothing: \(roadie.describe(find))")
        XCTAssertTrue(
            roadie.wait { roadie.textExists("homeassistant.local", in: roadie.app) },
            "the offered server isn't homeassistant.local")
    }

    func testMusicAssistantTab() {
        launchReady(scenario: "libraryIdle")
        openSettings(tab: "Music Assistant", marker: "ma.servers")
        let servers = roadie.element("ma.servers")
        XCTAssertTrue(roadie.wait { serverRows(servers).count >= 1 }, "no seeded server: \(roadie.describe(servers))")
        let first = serverRows(servers).element(boundBy: 0)
        tap(first)

        let name = roadie.element("ma.name")
        let address = roadie.element("ma.address")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no server editor")
        XCTAssertTrue(roadie.waitForValue(name) { $0 == "Scripted Music Assistant" }, "name: \(roadie.value(of: name))")
        XCTAssertTrue(roadie.waitForValue(address) { $0.contains("ma.example") }, "address: \(roadie.value(of: address))")
        let token = roadie.element("ma.token")
        XCTAssertTrue(
            roadie.wait { (token.placeholderValue ?? "").contains("Saved in Keychain") },
            "token prompt: \(token.placeholderValue ?? "nil")")

        // The seeded server already reads "Verified: …"; ma.status only shows once a test has run.
        let status = roadie.element("ma.status")
        XCTAssertFalse(status.exists, "ma.status before Test Connection: \(text("ma.status"))")
        // The recordings' host, http://ma.example:8095, is neither local nor Tailscale, so the editor flags it ("Use
        // https…") and Test Connection is disabled (run 20261029-193431-29071's screenshot). Move the server to a
        // `.local` name first: the stub answers `/info` for any host with the same server id, so it stays this server.
        replaceText(address, with: "ma.local:8095\r")
        XCTAssertTrue(roadie.waitForValue(address) { $0.contains("ma.local") }, "address: \(roadie.value(of: address))")
        let test = roadie.element("ma.test")
        XCTAssertTrue(roadie.wait { test.isEnabled }, "Test Connection disabled at ma.local:8095")
        tap(test)
        XCTAssertTrue(
            roadie.wait(timeout: 15) { text("ma.status").contains("Connected to Scripted Music Assistant") },
            "Test Connection never connected: \(text("ma.status"))")

        // Check Now runs a server resolution: the probe counts them (the scripted one finishes too fast to see the
        // button disabled).
        // The address change above re-resolves on its own: let that finish before counting.
        let checkNow = roadie.element("ma.checkNow")
        XCTAssertTrue(roadie.wait(timeout: 15) { checkNow.isEnabled }, "a resolution never finished")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let resolutions = roadie.probe?.maResolutions
        XCTAssertNotNil(resolutions, "probe lacks maResolutions: \(roadie.probeJSON)")
        tap(checkNow)
        XCTAssertTrue(
            roadie.wait(timeout: 15) { (roadie.probe?.maResolutions ?? 0) > (resolutions ?? 0) && checkNow.isEnabled },
            "Check Now ran no resolution; probe: \(roadie.probeJSON)")
        XCTAssertFalse(text("ma.reason").trimmingCharacters(in: .whitespaces).isEmpty, "ma.reason is empty")

        // Add a second server; the scripted factory answers for any host, and accepts any token.
        let before = serverRows(servers).count
        tap(roadie.element("ma.add"))
        XCTAssertTrue(roadie.wait { serverRows(servers).count == before + 1 },
            "Add Server added no row: \(roadie.describe(servers))")
        replaceText(name, with: "Second")
        replaceText(address, with: "ma2.local:8095\r")
        XCTAssertTrue(roadie.waitForValue(address) { $0.contains("ma2.local") }, "address: \(roadie.value(of: address))")
        XCTAssertTrue(roadie.wait { test.isEnabled }, "Test Connection disabled at ma2.local:8095")
        // No token stored for it: the server is found, and asks for one.
        tap(test)
        XCTAssertTrue(
            roadie.wait(timeout: 15) { text("ma.status").contains("Enter a token.") },
            "Test Connection without a token: \(text("ma.status"))")
        // A typed token: Test Connection connects and saves it, which enables Remove Token.
        replaceText(token, with: "second-server-token")
        tap(test)
        XCTAssertTrue(
            roadie.wait(timeout: 15) { text("ma.status").contains("Connected to Second") },
            "Test Connection with a token: \(text("ma.status"))")
        let removeToken = roadie.element("ma.removeToken")
        XCTAssertTrue(roadie.wait { removeToken.isEnabled }, "Remove Token disabled after the token was saved")
        XCTAssertTrue(
            roadie.wait { (token.placeholderValue ?? "").contains("Saved in Keychain") },
            "token prompt after saving: \(token.placeholderValue ?? "nil")")
        tap(removeToken)
        XCTAssertTrue(
            roadie.wait { (token.placeholderValue ?? "").contains("Long-lived token") && !removeToken.isEnabled },
            "Remove Token left the token; prompt: \(token.placeholderValue ?? "nil")")
        tap(roadie.element("ma.remove"))
        XCTAssertTrue(roadie.wait { serverRows(servers).count == before }, "Remove Server left the row")

        // This Mac.
        let sendspin = roadie.element("ma.sendspin.enabled")
        let was = roadie.probe?.sendspinEnabled
        XCTAssertNotNil(was, "probe lacks sendspinEnabled: \(roadie.probeJSON)")
        tap(sendspin)
        XCTAssertTrue(roadie.wait { roadie.probe?.sendspinEnabled == !(was ?? false) }, "the toggle didn't flip; probe: \(roadie.probeJSON)")
        let stopOnQuit = roadie.element("ma.stopOnQuit")
        let stopWas = isOn(stopOnQuit)
        tap(stopOnQuit)
        XCTAssertTrue(roadie.wait { isOn(stopOnQuit) != stopWas }, "Stop playback when Roadie quits didn't toggle")

        // Wi-Fi networks of the selected server.
        tap(first)
        let network = roadie.element("ma.networkName")
        XCTAssertTrue(network.waitForExistence(timeout: 5), "no network field")
        replaceText(network, with: "RoadieTestNet\r")
        XCTAssertTrue(hasText("RoadieTestNet", timeout: 5), "the network wasn't added")
        // The network row's Remove button, in the Settings window (the playlist's REM button is also labelled "Remove").
        let remove = settingsWindow.buttons.matching(NSPredicate(format: "label == 'Remove'")).firstMatch
        tap(remove)
        XCTAssertTrue(roadie.wait { !roadie.textExists("RoadieTestNet", in: settingsWindow) }, "the network wasn't removed")
        // No Wi-Fi access in the guest: Use Current Network must not crash or add a name.
        tap(roadie.element("ma.useCurrentNetwork"))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(roadie.main.play.exists, "the app went away after Use Current Network")
        XCTAssertFalse(remove.exists, "Use Current Network added a network in the guest")
        // Find Servers lives in the Library window; libraryTab covers it.
    }

    func testUpdatesTab() {
        launchReady()
        openSettings(tab: "Updates", marker: "updates.checkNow")
        XCTAssertFalse(roadie.element("updates.autoCheck").isEnabled, "auto-check enabled in Debug")
        XCTAssertFalse(roadie.element("updates.autoDownload").isEnabled, "auto-download enabled in Debug")
        XCTAssertFalse(roadie.element("updates.checkNow").isEnabled, "Check Now enabled in Debug")
        XCTAssertTrue(hasText("Updates are off in development builds."), "no development-build note")
        XCTAssertTrue(hasText("Last checked"), "no last-check row")
        let appMenu = roadie.app.menuBars.menuBarItems.element(boundBy: 1)
        appMenu.click()
        let item = appMenu.menuItems["Check for Updates…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Check for Updates… item")
        XCTAssertFalse(item.isEnabled, "Check for Updates… enabled in Debug")
        roadie.app.typeKey(.escape, modifierFlags: [])
    }

    func testSettingsTabPersists() {
        launchReady()
        // The Skins and Visualization tabs' own tests are #0208's and #0241's; here they only have to exist.
        openSettings(tab: "Library", marker: "library.source")
        // The tab buttons' labels read "" (run 20261029-190624-17832), but subscripting by title matches, as in selectTab.
        let names = ["Library", "Music Assistant", "Skins", "Visualization", "Updates"]
        let buttons = roadie.app.toolbars.buttons
        XCTAssertEqual(buttons.count, names.count, "Settings' tab count")
        for name in names { XCTAssertTrue(buttons[name].exists, "Settings has no \(name) tab") }
        selectTab("Visualization", marker: "vis.settings.interval")
        selectTab("Skins", marker: "skins.folder")
        roadie.app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(roadie.wait { !roadie.element("skins.folder").exists }, "⌘W didn't close Settings")
        roadie.app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(roadie.element("skins.folder").waitForExistence(timeout: 10), "Settings didn't reopen on Skins")

        // The choice is stored (`settingsSelectedTab`): a relaunch on the same defaults opens Settings on Skins.
        roadie.terminate()
        launchReady(keepingDefaults: true)
        roadie.app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            roadie.element("skins.folder").waitForExistence(timeout: 10), "Settings didn't open on Skins after a relaunch")
        XCTAssertFalse(roadie.element("library.source").exists, "Settings opened on Library after a relaunch")
    }
}
