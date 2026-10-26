import XCTest

/// Every manifest skin (scripts/test-skins.tsv) renders the three windows and both shade modes (#0208, design §5.8).
/// `--ui-skins all` (ROADIE_TEST_SKIN_SET=all, milestone runs) covers all seven; otherwise only `base-2.91`.
/// Each skin attaches a screenshot of the column, kept always.
final class SkinSmokeUITests: RoadieUITestCase {
    func testSmokeEverySkin() throws {
        continueAfterFailure = true  // one broken skin shouldn't hide the others
        let skins = try manifestSkins()
        XCTAssertFalse(skins.isEmpty, "no skins to smoke")
        for skin in skins {
            XCTContext.runActivity(named: skin.rawValue) { _ in smoke(skin) }
        }
    }

    /// The manifest's names, in its order; only `base-2.91` unless ROADIE_TEST_SKIN_SET is `all`.
    private func manifestSkins() throws -> [TestSkin] {
        guard ProcessInfo.processInfo.environment["ROADIE_TEST_SKIN_SET"] == "all" else { return [.base291] }
        let tsv = (paths.skins as NSString).appendingPathComponent("test-skins.tsv")
        let text = try String(contentsOfFile: tsv, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line -> TestSkin? in
            guard !line.hasPrefix("#"), let name = line.split(separator: "\t").first else { return nil }
            let skin = TestSkin(rawValue: String(name))
            XCTAssertNotNil(skin, "\(name) in test-skins.tsv isn't a TestSkin case")
            return skin
        }
    }

    private func smoke(_ skin: TestSkin) {
        let name = skin.rawValue
        launch(skin: skin, windows: [.main, .equalizer, .playlist])
        guard roadie.main.play.waitForExistence(timeout: 15) else {
            return XCTFail("\(name): main.play never appeared")
        }
        XCTAssertTrue(roadie.wait(timeout: 10) { self.roadie.probe?.skin == name }, "\(name): probe \(roadie.probeJSON)")

        // 1. Three windows, docked in a column, at the skin's sizes: skin pixels (the playlist 116 + 3 × 29 tall, from
        // `-playlistWindowSize`) times the base scale, 2 points per pixel (`PlayerModel.baseScale`).
        let frames = [AXID.Main.play, AXID.EQ.on, AXID.PL.scrollbar].map { windowFrame(containing: $0) }
        let scale: CGFloat = 2
        let sizes = [CGSize(width: 275, height: 116), CGSize(width: 275, height: 116), CGSize(width: 275, height: 203)]
            .map { CGSize(width: $0.width * scale, height: $0.height * scale) }
        for (i, frame) in frames.enumerated() {
            guard let frame else {
                XCTFail("\(name): window \(i) (main, EQ, playlist) missing")
                continue
            }
            XCTAssertEqual(frame.size, sizes[i], "\(name): window \(i) size")
        }
        if let main = frames[0], let eq = frames[1], let pl = frames[2] {
            XCTAssertEqual(main.minX, eq.minX, accuracy: 1, "\(name): EQ not under main")
            XCTAssertEqual(eq.minX, pl.minX, accuracy: 1, "\(name): playlist not under EQ")
            XCTAssertEqual(main.maxY, eq.minY, accuracy: 1, "\(name): EQ not docked to main")
            XCTAssertEqual(eq.maxY, pl.minY, accuracy: 1, "\(name): playlist not docked to EQ")
        }

        // 2. Controls, and the playlist rows once the fixture album plays.
        for id in [AXID.Main.play, AXID.EQ.on] {
            XCTAssertTrue(roadie.element(id).exists, "\(name): no \(id)")
        }
        roadie.playToneAlbum()
        if let queue = roadie.probe?.queue {
            for (i, item) in queue.prefix(5).enumerated() {
                let row = roadie.playlist.row(i)
                XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name): no pl.row.\(i)")
                XCTAssertTrue(row.label.contains(item.title), "\(name): pl.row.\(i) \"\(row.label)\", queue \(item.title)")
            }
        }

        // 3. Shade each window and back (Window menu shortcuts: no coordinate clicks on skinned controls).
        roadie.app.typeKey("w", modifierFlags: [.command, .control])
        let shadeTime = roadie.element(AXID.Shade.Main.time)
        if shadeTime.waitForExistence(timeout: 5) {
            let first = roadie.value(of: shadeTime)
            XCTAssertTrue(
                roadie.waitForValue(shadeTime, timeout: 5) { $0 != first }, "\(name): shade.main.time stuck at \(first)")
        } else {
            XCTFail("\(name): ⌃⌘W didn't shade the main window")
        }
        roadie.app.typeKey("w", modifierFlags: [.command, .control])
        XCTAssertTrue(roadie.wait { !shadeTime.exists }, "\(name): main window stayed shaded")

        roadie.app.typeKey("e", modifierFlags: [.command, .control])
        let eqShade = roadie.element(AXID.Shade.EQ.volume)
        XCTAssertTrue(eqShade.waitForExistence(timeout: 5), "\(name): ⌃⌘E didn't shade the EQ")
        roadie.app.typeKey("e", modifierFlags: [.command, .control])
        XCTAssertTrue(roadie.wait { !eqShade.exists }, "\(name): EQ stayed shaded")

        roadie.app.typeKey("p", modifierFlags: [.command, .control])
        let plShade = roadie.element(AXID.Shade.PL.title)
        XCTAssertTrue(plShade.waitForExistence(timeout: 5), "\(name): ⌃⌘P didn't shade the playlist")
        roadie.app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(roadie.wait { !plShade.exists }, "\(name): playlist stayed shaded")

        // 4. The main pop-up menu opens and closes. Its button shows only on the key main window (Window › Player, ⌘1).
        roadie.app.typeKey("1", modifierFlags: .command)
        let menuButton = roadie.element(AXID.Main.Title.menu)
        if menuButton.waitForExistence(timeout: 3) {
            roadie.click(menuButton)
            let popUp = roadie.main.popUpMenu
            XCTAssertTrue(popUp.waitForExistence(timeout: 3), "\(name): pop-up menu didn't open")
            roadie.app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(roadie.wait { !popUp.exists }, "\(name): pop-up menu didn't close")
        } else {
            XCTFail("\(name): no \(AXID.Main.Title.menu)")
        }

        // 6. Per-skin checks.
        switch skin {
        case .expensiveHiFi:
            // The top-left corner is transparent in region.txt: a click there reaches no control.
            // Offsets from the main window: the application element has no finite frame on macOS, so a coordinate
            // taken from it is infinite.
            let window = roadie.app.windows.containing(NSPredicate(format: "identifier == %@", AXID.Main.play)).firstMatch
            if window.exists {
                let before = roadie.probe
                window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: 1)).click()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                XCTAssertEqual(roadie.probe?.skin, before?.skin, "\(name): transparent click changed the skin")
                XCTAssertEqual(roadie.probe?.queue.count, before?.queue.count, "\(name): transparent click changed the queue")
            } else {
                XCTFail("\(name): no main window for the transparent click")
            }
        case .windowsClassic, .pikaAmp:
            XCTAssertTrue(roadie.playlist.row(0).exists, "\(name): pl.row.0 missing")
        default:
            break
        }

        // 5. The column's screenshot, always kept: what each skin looks like in Roadie.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        roadie.stopPlayback()
        roadie.terminate()
    }

    private func windowFrame(containing id: String) -> CGRect? {
        roadie.app.windows.allElementsBoundByIndex.first {
            $0.descendants(matching: .any).matching(identifier: id).count > 0
        }?.frame
    }
}
