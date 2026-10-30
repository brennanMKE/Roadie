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
    /// The applied skin's name (#0208), nil with none.
    var skin: String?
    /// The skins folder's `.wsz` files, folder-relative (#0208): the runner is sandboxed, so file checks read this.
    var skinFiles: [String]?
    /// The visualization window (#0235), nil until it first opens.
    var visualization: VisProbe?
    /// #0202's test-mode panel hook: `openFiles replace=true`, `saveEQF`, … Optional so an older app still decodes.
    var panelRequests: [String]?
    var alwaysOnTop: Bool?
    var doubleSize: Bool?
    /// The model state behind main.shuffle, main.repeat and main.time (#0202).
    var shuffle: Bool?
    var repeatAll: Bool?
    var timeMode: String?
    var sendspinEnabled: Bool?
    /// The UI-test suite's stored `firstRunVersion` (#0209); nil when unset.
    var firstRunVersion: Int?
    /// Music Assistant server resolutions started (#0209); nil outside UI-test mode.
    var maResolutions: Int?
    /// The equalizer (#0207); nil from an older app.
    var eq: EQProbe?

    struct EQProbe: Decodable {
        var isEnabled: Bool
        var preamp: Float
        var gains: [Float]
        var windowOpen: Bool
        var shaded: Bool
    }

    struct VisProbe: Decodable {
        var open: Bool
        var rendering: Bool
        var renderer: String?
        var preset: String?
        var presetName: String?
        var order: String
        var locked: Bool
        var audio: String
        var presetChanges: Int
        var fullScreen: Bool
        var lastTransition: String?
        var overlay: String
        var cursorHidden: Bool
        var songTitleShows: Int
        var readouts: [String]
        var help: Bool
        var autoAdvance: String
        var dimmed: Bool
        var flashNotice: Bool
    }
}

/// The skins folder a launch indexes (#0208).
enum SkinsFolder {
    /// `ROADIE_TEST_SKINS` itself (read-only use).
    case testSkins
    /// Another folder, e.g. the test's own copy (`RoadieUITestCase.launch(mutatesSkins:)`).
    case path(String)
    /// No `-skinsFolderPath` at all: no library, the Skins menu's navigation disabled.
    case none
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
        scenario: String? = nil, firstRun: Bool = false, windows: Windows = [.main, .playlist], volume: Int = 50,
        skinsFolder: SkinsFolder = .testSkins, loadsSkin: Bool = true, seedOmitting: [TestSkin]? = nil,
        museumFeatured: TestSkin? = nil, openFiles: [String] = [], keepingDefaults: Bool = false, extra: [String] = []
    ) {
        if let reason = Self.notGuestReason {
            XCTFail(reason)
            return
        }
        let args = launchArguments(
            testName: testName, paths: paths, skin: skin, library: library, scenario: scenario, firstRun: firstRun,
            windows: windows, volume: volume, skinsFolder: skinsFolder, loadsSkin: loadsSkin,
            seedOmitting: seedOmitting, museumFeatured: museumFeatured, openFiles: openFiles)
        if keepingDefaults {
            // A relaunch within one test (#0202): same data dir, same defaults suite, so what persists is checked.
            app.launchArguments = args + ["-RoadieKeepDefaults", "1"] + extra
            app.launch()
            return
        }
        // A fresh install each launch. Test mode empties the app's own suite; this was meant to clear the `.standard`
        // domain that AppKit's frame autosave and SwiftUI's scene storage write (#0194), but the runner is sandboxed, so
        // it is a no-op there (#0202): `-RoadieWindowLayout column` is what keeps the layout known.
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", "co.sstools.roadie"]
        defaults.standardOutput = FileHandle.nullDevice
        defaults.standardError = FileHandle.nullDevice
        if (try? defaults.run()) != nil { defaults.waitUntilExit() }

        app.launchArguments = args + extra
        app.launch()
    }

    private func launchArguments(
        testName: String, paths: Paths, skin: TestSkin, library: TestLibrary, scenario: String?, firstRun: Bool,
        windows: Windows, volume: Int, skinsFolder: SkinsFolder, loadsSkin: Bool, seedOmitting: [TestSkin]?,
        museumFeatured: TestSkin?, openFiles: [String]
    ) -> [String] {
        // The app creates it: the sandboxed runner can't write outside its container (#0202, #0208).
        let dataDir = Self.dataDirectory(testName: testName, paths: paths)
        var args = [
            "-RoadieUITest", "1",
            "-RoadieDataDir", dataDir,
            "-RoadieNoDiscovery", "1",
            "-RoadieMuseum", "fixtures",
            "-RoadieExternalOpens", "record",
            "-firstRunVersion", firstRun ? "0" : "1",
            "-eqWindowOpen", windows.contains(.equalizer) ? "YES" : "NO",
            "-playlistWindowOpen", windows.contains(.playlist) ? "YES" : "NO",
            // The playlist at its smallest width and three steps taller (`PlaylistModel.sizeKey`, [width, height]
            // steps). XML, so the elements are numbers: the old-style "(0, 3)" reads back as strings.
            "-playlistWindowSize", "<array><integer>0</integer><integer>3</integer></array>",
            // Main, equalizer and playlist in a column at the screen's top-left; the Library and the other windows
            // move right of it when they come forward, so none covers a skinned control (#0200 review).
            "-RoadieWindowLayout", "column",
            // The player's launch volume in percent, so `main.volume`'s value is known (#0200 review).
            "-RoadieVolume", String(volume),
            "-SUEnableAutomaticChecks", "NO",
            // No window restoration: SwiftUI's scene storage (the Skins window's tab) outlived the test that set it (#0208).
            "-ApplePersistenceIgnoreState", "YES",
        ]
        let folder: String?
        switch skinsFolder {
        case .testSkins: folder = paths.skins
        case .path(let path): folder = path
        case .none: folder = nil
        }
        if loadsSkin {
            args += ["-lastSkinPath", ((folder ?? paths.skins) as NSString).appendingPathComponent("\(skin.rawValue).wsz")]
        }
        if let folder { args += ["-skinsFolderPath", folder] }
        // The app empties `folder` and copies TestSkins' `.wsz` files into it, less `seedOmitting` (#0208).
        if let seedOmitting, folder != nil {
            args += ["-RoadieSeedSkins", paths.skins, "-RoadieSeedSkinsOmit", seedOmitting.map(\.rawValue).joined(separator: ",")]
        }
        // The fixture Museum serves TestSkins' files (read only) and leads its browse page with `museumFeatured`.
        if let museumFeatured {
            args += ["-RoadieMuseumSkins", paths.skins, "-RoadieMuseumFeatured", museumFeatured.rawValue]
        }
        if case .folder = library {
            args += ["-LibraryFolderPath", paths.music, "-LibrarySource", "folder"]
        }
        if let scenario { args += ["-RoadieMAScenario", scenario] }
        // The queue at launch, stopped at row 0, and File › Open…'s answer (#0203's `PanelStandIns`).
        if !openFiles.isEmpty { args += ["-RoadieOpenFiles", openFiles.joined(separator: "|")] }
        return args
    }

    func terminate() { app.terminate() }

    /// This test's data directory (what `-RoadieDataDir` gets), for files a test writes or reads.
    static func dataDirectory(testName: String, paths: Paths) -> String {
        (paths.data as NSString).appendingPathComponent(testName)
    }

    // MARK: Elements

    /// Any element with this identifier (skinned controls aren't all buttons).
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Whether a static text under `root` has `text` in its label or its value, as two queries: a SwiftUI section header
    /// has only a label, a row's text only a value, and one OR-ed predicate missed the headers (#0209).
    func textExists(_ text: String, in root: XCUIElement) -> Bool {
        let texts = root.descendants(matching: .staticText)
        return texts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
            || texts.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.exists
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
        /// The options pop-up (`main.title.menu`) while it is open. `NSMenu.popUp(positioning:at:in:)` puts it under the
        /// main window in the accessibility tree, not under the application (#0208).
        var popUpMenu: XCUIElement {
            ui.app.windows.containing(NSPredicate(format: "identifier == %@", AXID.Main.play))
                .descendants(matching: .menu).firstMatch
        }
    }

    @MainActor
    struct Playlist {
        let ui: RoadieUIApp
        func row(_ i: Int) -> XCUIElement { ui.element(AXID.PL.row(i)) }

        /// Opens a skinned pop-up menu (`AXID.PL.Menu.add` …) and clicks one of its entries (`pl.menu.add.dir` …).
        func menu(_ button: String, _ entry: String, file: StaticString = #filePath, line: UInt = #line) {
            ui.click(ui.element(button), file: file, line: line)
            let item = ui.element(entry)
            XCTAssertTrue(item.waitForExistence(timeout: 3), "\(button) didn't show \(entry)", file: file, line: line)
            ui.click(item, file: file, line: line)
        }

        /// An item of the SORT LIST / MISC OPTIONS pop-up or the right-click menu (#0229) while it is open. Looked up
        /// under the app's windows, not the application, so it can't match #0226's menu-bar Playlist menu, which has
        /// the same titles (#0230): a match there makes XCUITest traverse the menu bar while the pop-up is still
        /// tracking.
        func popUpMenuItem(_ title: String) -> XCUIElement {
            ui.app.windows.descendants(matching: .menuItem).matching(NSPredicate(format: "title == %@", title)).firstMatch
        }
    }

    /// The visualization window (#0235).
    @MainActor
    struct Visualization {
        let ui: RoadieUIApp
        /// By identifier (the title changes with the preset).
        var window: XCUIElement { ui.app.windows[AXID.Vis.window] }
        /// The top strip's preset name.
        var preset: String { ui.value(of: ui.element(AXID.Vis.preset)) }
        var probe: ProbeState.VisProbe? { ui.probe?.visualization }
        /// The flashing notice already seen (#0242): every visualization launch passes it but the notice's own test.
        static let flashNoticeShown = ["-visualization.flashNoticeShown", "YES"]

        /// ⇧⌘K (Window › Visualization), with the main window key.
        func open() {
            ui.app.typeKey("k", modifierFlags: [.command, .shift])
        }
    }

    var main: Main { Main(ui: self) }
    var visualization: Visualization { Visualization(ui: self) }
    var playlist: Playlist { Playlist(ui: self) }

    var probeElement: XCUIElement { element(AXID.probe) }

    var probeJSON: String { (probeElement.exists ? probeElement.value as? String : nil) ?? "{}" }

    var probe: ProbeState? { try? JSONDecoder().decode(ProbeState.self, from: Data(probeJSON.utf8)) }

    /// Clicks an element, or its centre when it isn't hittable (`pl.row.N` sits under `PlaylistListInputView`, #0199),
    /// but only once no other window covers that centre (`uncoveredCentre`); a failure points at the caller.
    func click(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if element.isHittable {
            element.click()
        } else if uncoveredCentre(element, file: file, line: line) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
    }

    func doubleClick(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if element.isHittable {
            element.doubleClick()
        } else if uncoveredCentre(element, file: file, line: line) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        }
    }

    /// Whether a coordinate click on `element`'s centre reaches the element's own window: a coordinate click lands on
    /// whatever is on top there (run 20261024-224212-18524's stop click went to the Library window). An overlap inside
    /// the element's window is fine (`pl.row.N` under `PlaylistListInputView`); another window in front of it at that
    /// point isn't. Then the element's window comes forward (`bringForward`) and the check runs again; still covered,
    /// it fails naming the element, the point and the covering window. `app.windows` lists windows front to back (the
    /// AX window order).
    private func uncoveredCentre(_ element: XCUIElement, file: StaticString, line: UInt) -> Bool {
        let id = element.identifier
        let frame = element.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        for attempt in 0..<2 {
            let windows = app.windows.allElementsBoundByIndex
            guard
                let own = windows.firstIndex(where: {
                    !id.isEmpty && $0.descendants(matching: .any).matching(identifier: id).count > 0
                })
            else {
                XCTFail("no window contains \(id.isEmpty ? "<no identifier>" : id): \(describe(element))", file: file, line: line)
                return false
            }
            let front = windows[..<own].filter { $0.exists }.map(\.frame)
            guard let covering = windows[..<own].first(where: { $0.exists && $0.frame.contains(point) }) else {
                return true
            }
            if attempt == 0, bringForward(windows[own], avoiding: front) { continue }
            XCTFail(
                "\(id) at \(point) is covered by window \"\(covering.title)\" (\(covering.identifier)) at \(covering.frame): "
                    + describe(element), file: file, line: line)
            return false
        }
        return false
    }

    /// Clicks the first point along the top strip of `window` (its title bar: a drag area in a skinned window, away
    /// from the options button and the close buttons at its ends) that no window in `front` covers. false when every
    /// candidate is covered.
    private func bringForward(_ window: XCUIElement, avoiding front: [CGRect]) -> Bool {
        let frame = window.frame
        for dx in [0.5, 0.4, 0.6, 0.3, 0.7] {
            let point = CGPoint(x: frame.minX + frame.width * dx, y: frame.minY + 6)
            guard !front.contains(where: { $0.contains(point) }) else { continue }
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY)).click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            return true
        }
        return false
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
    /// fraction: AXValue is Float precision (60 % reads 60.00000238418579), and every slider steps by whole percent,
    /// so numbers round to the nearest integer. "" when the element is missing or has no value.
    func value(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        switch element.value {
        case let text as String:
            return text
        case let number as NSNumber:
            let d = number.doubleValue.rounded()
            return abs(d) < 1e15 ? String(Int(d)) : number.stringValue
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
        click(albums, file: file, line: line)
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
        doubleClick(row, file: file, line: line)
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

    /// The folder the last `launch(mutatesSkins: true)` indexes: this test's own copy of `TestSkins/`.
    var skinsCopy: String?

    /// `mutatesSkins`: index a fresh copy of `TestSkins/` (`<ROADIE_TEST_DATA>/<testName>-skins`, only the `.wsz`
    /// files) instead of the shared folder, so a test can add or trash skins (#0208). The app makes the copy on the
    /// first such launch (`-RoadieSeedSkins`; the sandboxed runner can't write it); it survives relaunches.
    /// `withoutSkins` leaves those manifest skins out of the copy (a Museum download then adds one back).
    /// `museumFeatured`: the fixture Museum's browse page leads with that skin (`-RoadieMuseumFeatured`).
    /// `openFiles`: the queue at launch, stopped at row 0 (`-RoadieOpenFiles`); don't also pass `-RoadieOpenFiles` in
    /// `extra`, since the later value would win and the test would read the wrong queue.
    func launch(
        skin: TestSkin = .base291, library: TestLibrary = .folder, scenario: String? = nil, firstRun: Bool = false,
        windows: Windows = [.main, .playlist], volume: Int = 50, skinsFolder: SkinsFolder = .testSkins,
        mutatesSkins: Bool = false, withoutSkins: [TestSkin] = [], loadsSkin: Bool = true,
        museumFeatured: TestSkin? = nil, openFiles: [String] = [], keepingDefaults: Bool = false, extra: [String] = []
    ) {
        var skinsFolder = skinsFolder
        var seedOmitting: [TestSkin]?
        if mutatesSkins {
            if skinsCopy == nil {
                skinsCopy = (paths.data as NSString).appendingPathComponent("\(testName)-skins")
                seedOmitting = withoutSkins
            }
            if let skinsCopy { skinsFolder = .path(skinsCopy) }
        }
        if roadie == nil {
            let roadie = RoadieUIApp()
            self.roadie = roadie
            addTeardownBlock { @MainActor [weak self] in self?.finish(roadie) }
        }
        roadie.launch(
            testName: testName, paths: paths, skin: skin, library: library, scenario: scenario, firstRun: firstRun,
            windows: windows, volume: volume, skinsFolder: skinsFolder, loadsSkin: loadsSkin,
            seedOmitting: seedOmitting, museumFeatured: museumFeatured, openFiles: openFiles,
            keepingDefaults: keepingDefaults, extra: extra)
    }

    /// A file in the fixture music folder (`scripts/make-test-library.sh`'s layout), e.g. `Tone Artist/Tone Album/01 Tone A.mp3`.
    func music(_ relative: String) -> String {
        (paths.music as NSString).appendingPathComponent(relative)
    }

    /// This test's data directory (`-RoadieDataDir`).
    var dataDirectory: String { RoadieUIApp.dataDirectory(testName: testName, paths: paths) }
}
