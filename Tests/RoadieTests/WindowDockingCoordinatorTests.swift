import AppKit
import SkinKit
import WindowDocking
import XCTest

@testable import Roadie

/// `WindowDockingCoordinator` (#0219) with the three skinned windows on an isolated model: the first-launch stack, the
/// legacy frame seed, off-screen recovery and the end of a drag, plus `SkinWindowController`'s backing change and
/// `show()` with no reference window. The geometry itself is the `WindowDocking` package's `WindowDockingTests`.
final class WindowDockingCoordinatorTests: PlayerModelTestCase {
    private var controllers: [SkinWindowController] = []

    override func tearDown() async throws {
        for controller in controllers { controller.window.orderOut(nil) }
        controllers = []
        try await super.tearDown()
    }

    private func makeWindows(
        _ model: PlayerModel
    ) -> (WindowDockingCoordinator, SkinWindowController, SkinWindowController, SkinWindowController) {
        let docking = WindowDockingCoordinator(model: model)
        let main = SkinWindowController(kind: .main, model: model, rootView: PlayerView())
        let eq = SkinWindowController(kind: .equalizer, model: model, rootView: EqualizerView())
        let playlist = SkinWindowController(kind: .playlist(model.playlist.steps), model: model, rootView: PlaylistView())
        for controller in [main, eq, playlist] { docking.register(controller) }
        controllers = [main, eq, playlist]
        return (docking, main, eq, playlist)
    }

    func testFirstLaunchStacksDefaultLayout() throws {
        let model = try makeModel()
        model.setEQWindowOpen(true)
        model.setPlaylistWindowOpen(true)
        let (docking, main, eq, playlist) = makeWindows(model)
        docking.restoreOrDefaultLayout()
        XCTAssertTrue(main.isPositioned)
        XCTAssertTrue(eq.isPositioned)
        XCTAssertTrue(playlist.isPositioned)
        XCTAssertEqual(main.window.frame.minY, eq.window.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(eq.window.frame.minY, playlist.window.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(main.window.frame.minX, eq.window.frame.minX, accuracy: 0.5)
        XCTAssertEqual(main.window.frame.minX, playlist.window.frame.minX, accuracy: 0.5)
        // The group is centred on the primary screen's work area (`LayoutRules.stackedAndCentered` rounds up).
        let screen = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        let group = main.window.frame.union(eq.window.frame).union(playlist.window.frame)
        XCTAssertEqual(group.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(group.midY, screen.midY, accuracy: 1)
    }

    func testLegacyFramesSeedLayout() throws {
        let model = try makeModel()
        let seeds: [(name: String, x: Int, y: Int)] = [
            (SkinWindowKind.main.legacyAutosaveName, 100, 600),
            (SkinWindowKind.equalizer.legacyAutosaveName, 100, 400),
            (SkinWindowKind.playlist(.zero).legacyAutosaveName, 400, 300),
        ]
        for seed in seeds {
            model.defaults.set("\(seed.x) \(seed.y) 275 116 0 0 1440 900", forKey: "NSWindow Frame \(seed.name)")
        }
        let (docking, main, eq, playlist) = makeWindows(model)
        docking.restoreOrDefaultLayout()
        for (seed, controller) in zip(seeds, [main, eq, playlist]) {
            XCTAssertTrue(controller.isPositioned, seed.name)
            XCTAssertEqual(controller.window.frame.minX, CGFloat(seed.x), accuracy: 0.5, seed.name)
            // The top-left corner is kept: the seeded frame's top is y + 116.
            XCTAssertEqual(controller.window.frame.maxY, CGFloat(seed.y + 116), accuracy: 0.5, seed.name)
            XCTAssertNil(model.defaults.object(forKey: "NSWindow Frame \(seed.name)"), seed.name)
        }
    }

    func testOffScreenWindowComesBack() throws {
        let model = try makeModel()
        let (docking, main, _, _) = makeWindows(model)
        main.isPositioned = true
        main.window.orderFront(nil)
        main.window.setFrameOrigin(NSPoint(x: -50_000, y: -50_000))
        XCTAssertFalse(NSScreen.screens.contains { $0.visibleFrame.intersects(main.window.frame) })
        docking.ensureOnScreen()
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(main.window.frame) })
        XCTAssertNotNil(WindowLayoutStore(defaults: model.defaults).load()?.windows[.main])
    }

    func testDragEndDocksWithinThreshold() throws {
        let model = try makeModel()
        let (docking, main, eq, _) = makeWindows(model)
        let screen = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        main.isPositioned = true
        eq.isPositioned = true
        // Keep every edge more than the snap distance from the screen's, whatever the scale: the main window near the
        // top, the equalizer 40 points below it.
        let gap: CGFloat = 40
        XCTAssertLessThan(main.window.frame.height + gap + eq.window.frame.height + 80, screen.height)
        main.window.setFrameTopLeftPoint(NSPoint(x: screen.midX - main.window.frame.width / 2, y: screen.maxY - 40))
        eq.window.setFrameTopLeftPoint(NSPoint(x: main.window.frame.minX, y: main.window.frame.minY - gap - 20))
        main.window.orderFront(nil)
        eq.window.orderFront(nil)
        let store = WindowLayoutStore(defaults: model.defaults)

        // Ends `gap` points below the main window: saved, not docked.
        docking.dragBegan(eq)
        docking.drag(eq, to: NSPoint(x: eq.window.frame.minX, y: main.window.frame.minY - gap - eq.window.frame.height))
        docking.dragEnded(eq)
        XCTAssertEqual(eq.window.frame.maxY, main.window.frame.minY - gap, accuracy: 0.5)
        let undocked = try XCTUnwrap(store.load()?.windows[.equalizer])

        // Ends 5 points below, inside the snap distance: docks under the main window.
        docking.dragBegan(eq)
        docking.drag(eq, to: NSPoint(x: eq.window.frame.minX, y: main.window.frame.minY - 5 - eq.window.frame.height))
        docking.dragEnded(eq)
        XCTAssertEqual(eq.window.frame.maxY, main.window.frame.minY, accuracy: 0.5)
        let docked = try XCTUnwrap(store.load()?.windows[.equalizer])
        XCTAssertEqual(docked.top - undocked.top, -gap, accuracy: 0.5)
    }

    func testBackingChangeReappliesLayout() throws {
        let model = try makeModel()
        let (_, main, _, _) = makeWindows(model)
        let laidOut = main.window.frame
        main.window.setContentSize(NSSize(width: 40, height: 40))
        XCTAssertNotEqual(main.window.frame.size, laidOut.size)
        main.windowDidChangeBackingProperties(Notification(name: NSWindow.didChangeBackingPropertiesNotification))
        XCTAssertEqual(main.window.frame.size, laidOut.size)
    }

    func testShowWithoutReferenceCentresUnpositionedWindow() throws {
        let model = try makeModel()
        let main = SkinWindowController(kind: .main, model: model, rootView: PlayerView())
        controllers = [main]
        main.window.setFrameOrigin(NSPoint(x: -50_000, y: -50_000))
        XCTAssertFalse(main.isPositioned)
        main.show()
        XCTAssertTrue(main.isPositioned)
        XCTAssertTrue(main.window.isVisible)
        // `NSWindow.center()`: horizontally centred on the screen it lands on.
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.visibleFrame.intersects(main.window.frame) })
        XCTAssertEqual(main.window.frame.midX, screen.visibleFrame.midX, accuracy: 1)
    }
}
