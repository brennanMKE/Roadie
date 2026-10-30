import XCTest

/// The equalizer window (#0207, design §5.4): on/off, bands, preamp, level labels, presets, graph, shade, close and
/// persistence. Folder library, base skin, all three windows, the Tone Album playing. Values are read from the probe's
/// `eq` (dB); the graph's accessibility value is a static text, so it is read directly.
final class EqualizerUITests: RoadieUITestCase {
    // MARK: Launch and geometry

    private func launchEQ(extra: [String] = [], keepingDefaults: Bool = false) {
        launch(windows: [.main, .equalizer, .playlist], openFiles: toneAlbum, keepingDefaults: keepingDefaults, extra: extra)
        XCTAssertTrue(element(AXID.EQ.on).waitForExistence(timeout: 10), "eq.on never appeared")
        XCTAssertTrue(roadie.wait { self.roadie.probe?.eq != nil }, "the probe has no eq; probe: \(roadie.probeJSON)")
        startQueued(count: toneAlbum.count)
    }

    private var eq: ProbeState.EQProbe? { roadie.probe?.eq }

    /// The equalizer window's scale (points per skin pixel).
    private var scale: CGFloat { eqWindow.frame.width / 275 }

    /// A point in the equalizer window, in skin pixels.
    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        eqWindow.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x * scale, dy: y * scale))
    }

    /// The pointer y (skin px, window space) where a slider at top `38` reads `value` (0...100): the inverse of
    /// `EQLayout.value(forPointerY:)` (thumb 11 px, travel 51 px).
    private func sliderY(forValue value: Double) -> CGFloat {
        38 + 5.5 + CGFloat(1 - value / 100) * 51
    }

    /// Drags a slider whose left edge is `x` (skin px) from its middle to where it reads `value`.
    private func dragSlider(x: CGFloat, to value: Double) {
        let start = point(x: x + 7, y: sliderY(forValue: 50) + 3)
        start.press(forDuration: 0.1, thenDragTo: point(x: x + 7, y: sliderY(forValue: value)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func dragBand(_ i: Int, to value: Double) { dragSlider(x: 78 + 18 * CGFloat(i), to: value) }
    private func dragPreamp(to value: Double) { dragSlider(x: 21, to: value) }

    private func expectEQ(
        _ what: String, file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping (ProbeState.EQProbe) -> Bool
    ) {
        XCTAssertTrue(
            roadie.wait { self.eq.map(predicate) ?? false }, "\(what); probe: \(roadie.probeJSON)", file: file, line: line)
    }

    nonisolated private static func near(_ a: Float, _ b: Float, _ tolerance: Float = 0.05) -> Bool { abs(a - b) <= tolerance }

    private var graphValue: String { roadie.value(of: element(AXID.EQ.graph)) }

    /// The graph's value for these gains: `EQLayout.accessibilityValue` joined by spaces.
    nonisolated private static func graphText(_ gains: [Float]) -> String {
        gains.map { String(format: "%.1f", Double($0)) }.joined(separator: " ")
    }

    // MARK: Presets (AudioCore's EQPreset, which this target doesn't link)

    /// `EQPreset.decibels(fromWinampValue:)`.
    nonisolated private static func decibels(_ v: Int) -> Float {
        let c = Float(min(max(v, 1), 64))
        let db = c >= 33 ? (c - 33) * 12 / 31 : (c - 33) * 12 / 32
        return (db * 10).rounded() / 10
    }

    /// The first three `EQPreset.builtIn` names, and Rock's values.
    private static let firstPresets = ["Flat", "Classical", "Club"]
    nonisolated private static let rock = [45, 40, 23, 19, 26, 39, 47, 50, 50, 50].map { decibels($0) }

    private func menuItem(_ title: String) -> XCUIElement {
        roadie.app.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    /// Opens PRESETS and, when `load`, its Load submenu.
    private func openPresets(load: Bool, file: StaticString = #filePath, line: UInt = #line) {
        roadie.click(element(AXID.EQ.presets), file: file, line: line)
        let loadItem = menuItem("Load")
        XCTAssertTrue(loadItem.waitForExistence(timeout: 5), "PRESETS didn't open its menu", file: file, line: line)
        if load {
            loadItem.click()
            XCTAssertTrue(menuItem("From EQF…").waitForExistence(timeout: 5), "Load had no submenu", file: file, line: line)
        }
    }

    // MARK: Tests

    func testBandsAndToggles() {
        launchEQ()
        let wasOn = eq?.isEnabled ?? false
        roadie.click(element(AXID.EQ.on))
        expectEQ("eq.on didn't toggle the equalizer") { $0.isEnabled == !wasOn }
        if let shown = toggleValue(AXID.EQ.on) { XCTAssertEqual(shown, !wasOn, "eq.on's shown state") }
        roadie.click(element(AXID.EQ.on))
        expectEQ("eq.on didn't toggle back") { $0.isEnabled == wasOn }

        let gainsBefore = eq?.gains ?? []
        XCTAssertEqual(gainsBefore.count, 10, "probe gains: \(roadie.probeJSON)")
        dragBand(3, to: 100)
        expectEQ("band 3 dragged to the top isn't +12") { $0.gains.count == 10 && Self.near($0.gains[3], 12) }
        if let gains = eq?.gains, gains.count == 10, gainsBefore.count == 10 {
            for i in 0..<10 where i != 3 {
                XCTAssertEqual(gains[i], gainsBefore[i], "band \(i) moved with band 3")
            }
        }
        dragPreamp(to: 25)
        expectEQ("preamp at a quarter isn't -6") { Self.near($0.preamp, -6, 0.3) }

        roadie.click(element(AXID.EQ.levelMinus))
        expectEQ("eq.level.minus didn't set every band to -12") { $0.gains.allSatisfy { Self.near($0, -12) } }
        roadie.click(element(AXID.EQ.levelPlus))
        expectEQ("eq.level.plus didn't set every band to +12") { $0.gains.allSatisfy { Self.near($0, 12) } }
        roadie.click(element(AXID.EQ.levelZero))
        expectEQ("eq.level.zero didn't set every band to 0") { $0.gains.allSatisfy { Self.near($0, 0) } }
        expectEQ("the level labels moved the preamp") { Self.near($0.preamp, -6, 0.3) }

        // AUTO is a no-op by design.
        let before = eq
        roadie.click(element(AXID.EQ.auto))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let after = eq
        XCTAssertEqual(after?.gains, before?.gains, "eq.auto changed the bands")
        XCTAssertEqual(after?.preamp, before?.preamp, "eq.auto changed the preamp")
        XCTAssertEqual(after?.isEnabled, before?.isEnabled, "eq.auto changed on/off")
    }

    func testPresetsMenu() {
        let file = (dataDirectory as NSString).appendingPathComponent("entry.eqf")
        launchEQ(extra: ["-RoadieSaveTo", file, "-RoadieLoadEQF", file])

        openPresets(load: true)
        for name in Self.firstPresets {
            XCTAssertTrue(menuItem(name).exists, "Load lists no \(name)")
        }
        XCTAssertTrue(menuItem("Save…").exists, "PRESETS has no Save…")
        menuItem("Rock").click()
        expectEQ("Rock didn't apply") { zip($0.gains, Self.rock).allSatisfy { Self.near($0, $1) } }
        XCTAssertTrue(
            roadie.wait { self.graphValue == Self.graphText(Self.rock) },
            "eq.graph is \"\(graphValue)\", not Rock's \(Self.graphText(Self.rock))")

        // Rock's preamp is 0, the default, so move it to -6 first: the round trip then proves the preamp too.
        // The first pointer press after the PRESETS menu closes didn't reach the window (run 20261029-203010-55326):
        // click the title strip to make the window key again, then drag, retrying once.
        clickTitleStrip(eqWindow, dx: 0.4)
        dragPreamp(to: 25)
        if !roadie.wait(timeout: 2, { self.eq.map { Self.near($0.preamp, -6, 0.3) } ?? false }) { dragPreamp(to: 25) }
        expectEQ("preamp at a quarter isn't -6") { Self.near($0.preamp, -6, 0.3) }
        // Save… writes the bands and preamp to the stand-in path; From EQF… reads them back after a reset.
        let savedPreamp = eq?.preamp ?? 0
        openPresets(load: false)
        menuItem("Save…").click()
        expectPanelRequest("saveEQF")
        clickTitleStrip(eqWindow, dx: 0.4)
        roadie.click(element(AXID.EQ.levelZero))
        dragPreamp(to: 50)
        expectEQ("the bands and preamp didn't reset to 0") {
            $0.gains.allSatisfy { Self.near($0, 0) } && Self.near($0.preamp, 0)
        }
        openPresets(load: true)
        menuItem("From EQF…").click()
        expectPanelRequest("loadEQF")
        expectEQ("From EQF… didn't load the saved file's bands") {
            // EQF stores 6-bit Winamp values: about 0.4 dB per step.
            $0.gains.count == 10 && zip($0.gains, Self.rock).allSatisfy { Self.near($0, $1) }
                && Self.near($0.preamp, savedPreamp, 0.5) && Self.near($0.preamp, -6, 0.6)
        }
        XCTAssertNil(roadie.probe?.notice, "loading the saved EQF posted a notice")
    }

    func testGraphValue() {
        launchEQ()
        roadie.click(element(AXID.EQ.levelZero))
        XCTAssertTrue(roadie.wait { self.graphValue == Self.graphText(Array(repeating: 0, count: 10)) }, graphValue)
        dragBand(0, to: 100)
        expectEQ("band 0 isn't +12") { $0.gains.count == 10 && Self.near($0.gains[0], 12) }
        let afterBand0 = "12.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0"
        XCTAssertTrue(roadie.wait { self.graphValue == afterBand0 }, "eq.graph after band 0: \(graphValue)")
        dragBand(9, to: 0)
        expectEQ("band 9 isn't -12") { $0.gains.count == 10 && Self.near($0.gains[9], -12) }
        let afterBand9 = "12.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 -12.0"
        XCTAssertTrue(roadie.wait { self.graphValue == afterBand9 }, "eq.graph after band 9: \(graphValue)")
        if let gains = eq?.gains { XCTAssertEqual(graphValue, Self.graphText(gains), "eq.graph doesn't match the bands") }
    }

    func testShadeAndClose() {
        launchEQ()
        clickTitleStrip(eqWindow, dx: 0.4)
        let shade = element(AXID.EQ.titleShade)
        XCTAssertTrue(shade.waitForExistence(timeout: 5), "eq.title.shade missing")
        roadie.click(shade)
        XCTAssertTrue(element(AXID.Shade.EQ.volume).waitForExistence(timeout: 5), "shade.eq.volume missing when shaded")
        XCTAssertTrue(element(AXID.Shade.EQ.balance).exists, "shade.eq.balance missing when shaded")
        expectEQ("the probe doesn't report the shade") { $0.shaded }
        let shaded = window(containing: AXID.Shade.EQ.volume)
        XCTAssertTrue(roadie.wait { abs(shaded.frame.height - 14 * self.scaleOf(shaded)) <= 1 }, "shaded EQ: \(shaded.frame)")

        roadie.app.typeKey("e", modifierFlags: [.command, .control])
        XCTAssertTrue(element(AXID.EQ.on).waitForExistence(timeout: 5), "⌃⌘E didn't unshade the equalizer")
        expectEQ("still shaded after ⌃⌘E") { !$0.shaded }

        clickTitleStrip(eqWindow, dx: 0.4)
        let close = element(AXID.EQ.titleClose)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "eq.title.close missing")
        roadie.click(close)
        XCTAssertTrue(roadie.wait { !self.element(AXID.EQ.on).exists }, "eq.title.close didn't close the window")
        expectEQ("the probe still reports the window open") { !$0.windowOpen }
        if let shown = toggleValue(AXID.Main.eq) { XCTAssertFalse(shown, "main.eq still selected after close") }

        focusMain()
        roadie.app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(element(AXID.EQ.on).waitForExistence(timeout: 5), "⌘2 didn't reopen the equalizer")
        expectEQ("the probe doesn't report the window open") { $0.windowOpen }
        XCTAssertTrue(
            roadie.wait { self.isDocked(self.eqWindow, under: self.mainWindow) },
            "EQ \(eqWindow.frame) not docked under main \(mainWindow.frame)")
    }

    private func scaleOf(_ window: XCUIElement) -> CGFloat { window.frame.width / 275 }

    func testEqPersistsAcrossRelaunch() {
        launchEQ()
        roadie.click(element(AXID.EQ.levelZero))
        expectEQ("eq.level.zero didn't zero the bands") { $0.gains.allSatisfy { Self.near($0, 0) } }
        dragBand(0, to: 100)
        dragPreamp(to: 25)
        if eq?.isEnabled != true { roadie.click(element(AXID.EQ.on)) }
        expectEQ("band 0 +12, preamp -6, on") {
            $0.gains.count == 10 && Self.near($0.gains[0], 12) && Self.near($0.preamp, -6, 0.3) && $0.isEnabled
        }
        let set = eq

        roadie.terminate()
        launchEQ(keepingDefaults: true)
        expectEQ("the equalizer didn't persist") {
            $0.isEnabled && $0.gains == set?.gains && $0.preamp == set?.preamp
        }
        XCTAssertTrue(
            roadie.wait { self.graphValue.hasPrefix("12.0 0.0 ") }, "eq.graph after relaunch: \(graphValue)")
    }
}
