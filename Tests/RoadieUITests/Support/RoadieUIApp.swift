import Foundation
import XCTest

/// Test skins from `scripts/test-skins.tsv` (#0198), cached on the host and copied into the guest's `TestSkins/`.
enum TestSkin: String, CaseIterable {
    case base291 = "base-2.91"
    case expensiveHiFi = "Expensive_HI_FI_Sony_2005"
    case base = "base"
    case windowsClassic = "Windows_Classic"
    case pikaAmp = "Pika_Amp"
    case windows98Amp = "Windows_98_Amp"
    case internetArchive = "internet-archive-winamp-skin-by-luigihann"
}

/// The windows open at launch. The main window always is.
struct Windows: OptionSet {
    let rawValue: Int
    static let main = Windows(rawValue: 1 << 0)
    static let equalizer = Windows(rawValue: 1 << 1)
    static let playlist = Windows(rawValue: 1 << 2)
}

enum TestLibrary {
    /// `scripts/make-test-library.sh`'s folder (ROADIE_TEST_MUSIC), source "folder".
    case folder
    /// No music folder configured.
    case none
}

/// What `state.probe` reports (the app's `TestProbe`, #0199).
struct ProbeState: Decodable {
    struct QueueItem: Decodable {
        var title: String
        var marker: String
        var current: Bool
    }

    var output: String
    var feed: String
    var state: String
    var currentIndex: Int?
    var queue: [QueueItem]
    var notice: String?
    var lastExternalOpen: String?
    var tokenStore: String
    var maRequests: [String]
}

/// Wraps `XCUIApplication` for Roadie in test mode (#0194). UI tests run only in the Tart guest
/// (docs/ui-tests-in-vm.md); `scripts/run-tests-vm.sh --ui` sets the ROADIE_TEST_* paths and ROADIE_UI_GUEST.
/// XCUIApplication and XCUIElement are main-actor APIs, so the harness and its accessors are too.
@MainActor
final class RoadieUIApp {
    let app = XCUIApplication()

    struct Paths {
        var skins: String
        var music: String
        var data: String
    }

    /// nil outside the VM run: the tests skip themselves rather than run anywhere else.
    nonisolated static var paths: Paths? {
        let env = ProcessInfo.processInfo.environment
        guard let skins = env["ROADIE_TEST_SKINS"], let music = env["ROADIE_TEST_MUSIC"] else { return nil }
        return Paths(
            skins: skins, music: music,
            data: env["ROADIE_TEST_DATA"] ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("roadie-test-data"))
    }

    /// Why this process must not launch Roadie or delete its defaults, or nil in the Tart guest. `launch` runs
    /// `defaults delete co.sstools.roadie`, which on a developer's Mac would wipe their real preferences, so it needs
    /// both run-tests-vm.sh's explicit ROADIE_UI_GUEST=1 and the guest's `admin` user.
    nonisolated static var notGuestReason: String? {
        let guest = ProcessInfo.processInfo.environment["ROADIE_UI_GUEST"]
        guard guest == "1" else {
            return "ROADIE_UI_GUEST=1 unset: UI tests launch Roadie and delete its defaults only in the Tart guest "
                + "(scripts/run-tests-vm.sh --ui)"
        }
        guard NSUserName() == "admin" else {
            return "user is \(NSUserName()), not the Tart guest's admin: refusing to launch Roadie or delete its defaults"
        }
        return nil
    }

    func launch(
        testName: String, paths: Paths, skin: TestSkin = .base291, library: TestLibrary = .folder,
        scenario: String? = nil, firstRun: Bool = false, windows: Windows = [.main, .playlist], extra: [String] = []
    ) {
        if let reason = Self.notGuestReason {
            XCTFail(reason)
            return
        }
        // A fresh install each launch. Test mode empties the app's own suite; this clears the `.standard` domain that
        // AppKit's frame autosave and SwiftUI's scene storage still write (#0194; harmless in the throwaway guest).
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", "co.sstools.roadie"]
        defaults.standardOutput = FileHandle.nullDevice
        defaults.standardError = FileHandle.nullDevice
        if (try? defaults.run()) != nil { defaults.waitUntilExit() }

        let dataDir = (paths.data as NSString).appendingPathComponent(testName)
        try? FileManager.default.removeItem(atPath: dataDir)
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

        var args = [
            "-RoadieUITest", "1",
            "-RoadieDataDir", dataDir,
            "-RoadieNoDiscovery", "1",
            "-RoadieMuseum", "fixtures",
            "-RoadieExternalOpens", "record",
            "-firstRunVersion", firstRun ? "0" : "1",
            "-lastSkinPath", (paths.skins as NSString).appendingPathComponent("\(skin.rawValue).wsz"),
            "-skinsFolderPath", paths.skins,
            "-eqWindowOpen", windows.contains(.equalizer) ? "YES" : "NO",
            "-playlistWindowOpen", windows.contains(.playlist) ? "YES" : "NO",
            "-SUEnableAutomaticChecks", "NO",
        ]
        if case .folder = library {
            args += ["-LibraryFolderPath", paths.music, "-LibrarySource", "folder"]
        }
        if let scenario { args += ["-RoadieMAScenario", scenario] }
        app.launchArguments = args + extra
        app.launch()
    }

    func terminate() { app.terminate() }

    // MARK: Elements

    /// Any element with this identifier (skinned controls aren't all buttons).
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func count(_ id: String) -> Int {
        app.descendants(matching: .any).matching(identifier: id).count
    }

    @MainActor
    struct Main {
        let ui: RoadieUIApp
        var play: XCUIElement { ui.element(AXID.Main.play) }
        var stop: XCUIElement { ui.element(AXID.Main.stop) }
        var previous: XCUIElement { ui.element(AXID.Main.previous) }
        var next: XCUIElement { ui.element(AXID.Main.next) }
        var marquee: XCUIElement { ui.element(AXID.Main.marquee) }
        var time: XCUIElement { ui.element(AXID.Main.time) }
        var volume: XCUIElement { ui.element(AXID.Main.volume) }
    }

    @MainActor
    struct Playlist {
        let ui: RoadieUIApp
        func row(_ i: Int) -> XCUIElement { ui.element(AXID.PL.row(i)) }
    }

    var main: Main { Main(ui: self) }
    var playlist: Playlist { Playlist(ui: self) }

    var probeElement: XCUIElement { element(AXID.probe) }

    var probeJSON: String { (probeElement.exists ? probeElement.value as? String : nil) ?? "{}" }

    var probe: ProbeState? { try? JSONDecoder().decode(ProbeState.self, from: Data(probeJSON.utf8)) }

    func menuItem(_ title: String) -> XCUIElement { app.menuItems[title].firstMatch }

    /// Clicks an element, or its centre when it isn't hittable (`pl.row.N` sits under `PlaylistListInputView`, #0199).
    func click(_ element: XCUIElement) {
        if element.isHittable {
            element.click()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
    }

    func doubleClick(_ element: XCUIElement) {
        if element.isHittable {
            element.doubleClick()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        }
    }

    // MARK: Waiting

    /// Polls `predicate` every 0.2 s until it holds or `timeout` passes.
    @discardableResult
    func wait(timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return predicate()
    }

    @discardableResult
    func waitForValue(_ element: XCUIElement, timeout: TimeInterval = 5, _ predicate: (String) -> Bool) -> Bool {
        wait(timeout: timeout) { predicate(value(of: element)) }
    }

    /// An element's accessibility value as text: a display's string (`skinDisplay`/`AXMarker` are static text, whose
    /// `AXValue` is the string), or a slider's number (`SkinSlider` is an `AXSlider`, `AXValue` 0...100) without a
    /// trailing `.0`. "" when the element is missing or has no value.
    func value(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        switch element.value {
        case let text as String:
            return text
        case let number as NSNumber:
            let d = number.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : number.stringValue
        default:
            return ""
        }
    }

    /// The element's snapshot (type, identifier, label, value, frame) for a failure message, capped at 2000 characters.
    func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "<no such element: \(element)>" }
        let text = element.debugDescription
        return text.count > 2000 ? String(text.prefix(2000)) + "…" : text
    }

    func waitForPlaying(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let ok = wait(timeout: timeout) { probe?.state == "playing" }
        XCTAssertTrue(ok, "never reached playing; probe: \(probeJSON)", file: file, line: line)
    }

    func expectCurrentRow(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        let ok = wait { probe?.currentIndex == n }
        XCTAssertTrue(ok, "current row isn't \(n); probe: \(probeJSON)", file: file, line: line)
    }

    /// Stops playback with Playback › Stop (⌃⌘V, a menu command, so it works whichever window is key; the Library
    /// window can cover `main.stop`, and a coordinate click there missed in run 20261024-224212-18524) and returns
    /// the probe's `currentIndex` once it reports `stopped`. Retries the shortcut up to three times.
    @discardableResult
    func stopPlayback(file: StaticString = #filePath, line: UInt = #line) -> Int? {
        for _ in 0..<3 {
            app.typeKey("v", modifierFlags: [.command, .control])
            if wait(timeout: 5, { probe?.state == "stopped" }) { return probe?.currentIndex }
        }
        XCTFail("Playback › Stop (⌃⌘V) never stopped the player; probe: \(probeJSON)", file: file, line: line)
        return nil
    }

    /// Opens the Library (⌘L), shows Albums and double-clicks the fixture library's "Tone Album" (three tracks), checking
    /// each step so a failure says which one broke: the Library opened, Albums listed the album, the row took the
    /// double-click, the queue filled, playback started.
    func playToneAlbum(file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("l", modifierFlags: .command)
        let albums = element(AXID.Library.sidebar("albums"))
        guard albums.waitForExistence(timeout: 10) else {
            return XCTFail(
                "⌘L didn't open the Library: no \(AXID.Library.sidebar("albums")); windows: \(app.windows.count)",
                file: file, line: line)
        }
        click(albums)
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'library.row.album.' AND identifier CONTAINS 'tone-album'")
        ).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            let rows = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'library.row.'")).count
            return XCTFail(
                "Tone Album never listed under Albums (\(rows) library.row.* elements; is ROADIE_TEST_MUSIC indexed?)",
                file: file, line: line)
        }
        XCTAssertTrue(
            wait(timeout: 5) { row.isHittable }, "Tone Album row isn't hittable: \(describe(row))", file: file, line: line)
        doubleClick(row)
        guard wait(timeout: 10, { !(probe?.queue.isEmpty ?? true) }) else {
            return XCTFail(
                "double-clicking Tone Album queued nothing: \(describe(row)); probe: \(probeJSON)", file: file, line: line)
        }
        waitForPlaying(file: file, line: line)
    }
}

/// The base class: skips outside the VM, attaches a screenshot and the probe on failure, and quits the app.
///
/// The test methods are main-actor (the class is). XCTestCase's setUpWithError is nonisolated, so its override is too
/// and touches no XCUI API. The XCUI teardown (screenshot, probe, terminate) is a main-actor teardown block that
/// `launch()` registers, so it runs only for tests that launched the app.
@MainActor
class RoadieUITestCase: XCTestCase {
    /// Created by `launch()`, on the main actor.
    nonisolated(unsafe) var roadie: RoadieUIApp!
    /// Set by `setUpWithError` (nonisolated), read by the main-actor `launch()`.
    nonisolated(unsafe) var paths: RoadieUIApp.Paths!

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
        guard let paths = RoadieUIApp.paths else {
            throw XCTSkip("ROADIE_TEST_SKINS/ROADIE_TEST_MUSIC unset: UI tests run only via scripts/run-tests-vm.sh --ui")
        }
        if let reason = RoadieUIApp.notGuestReason { throw XCTSkip(reason) }
        self.paths = paths
    }

    /// Attaches a screenshot and the probe (kept when the test failed) and quits the app. Runs as a teardown block.
    private func finish(_ roadie: RoadieUIApp) {
        let failed = testRun?.hasSucceeded == false
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "screen"
        screenshot.lifetime = failed ? .keepAlways : .deleteOnSuccess
        add(screenshot)
        let probe = XCTAttachment(string: roadie.probeJSON)
        probe.name = "probe.json"
        probe.lifetime = failed ? .keepAlways : .deleteOnSuccess
        add(probe)
        roadie.terminate()
        self.roadie = nil
    }

    /// `-[RoadieUITests.SmokeUITests testFoo]` → `testFoo`, the data directory's name.
    var testName: String {
        name.split(separator: " ").last.map { String($0.dropLast()) } ?? "test"
    }

    func launch(
        skin: TestSkin = .base291, library: TestLibrary = .folder, scenario: String? = nil, firstRun: Bool = false,
        windows: Windows = [.main, .playlist], extra: [String] = []
    ) {
        if roadie == nil {
            let roadie = RoadieUIApp()
            self.roadie = roadie
            addTeardownBlock { @MainActor [weak self] in self?.finish(roadie) }
        }
        roadie.launch(
            testName: testName, paths: paths, skin: skin, library: library, scenario: scenario, firstRun: firstRun,
            windows: windows, extra: extra)
    }
}
