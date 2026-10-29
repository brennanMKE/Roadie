import AppKit
import VisualizationKit
import XCTest

@testable import Roadie

/// Full screen in the visualization window (#0237): the model with a fake window, so nothing enters a Space.
@MainActor
final class VisualizationFullScreenTests: PlayerModelTestCase {
    /// Counts toggles and, like the window, reports the new state back to the model.
    private final class FakeWindow: FullScreenToggling {
        weak var model: VisualizationModel?
        var toggles = 0
        var reportsBack = true

        func toggleFullScreen() {
            toggles += 1
            guard reportsBack, let model else { return }
            model.setFullScreen(!model.isFullScreen)
        }
    }

    private var fake: FakeWindow!

    private func visModel() throws -> PlayerModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configuration.visSeed = 1
        let model = makeModel(configuration)
        fake = FakeWindow()
        fake.model = model.visualization
        model.visualization.fullScreenController = fake
        return model
    }

    func testOptionReturnAsksForFullScreen() throws {
        let vis = try visModel().visualization
        vis.open()
        let command = VisKeyMap.command(
            for: .returnKey, command: false, control: false, option: true, shift: false, isRepeat: false)
        XCTAssertEqual(command, .toggleFullScreen)
        XCTAssertTrue(vis.handleFullScreenCommand(.toggleFullScreen))
        XCTAssertEqual(fake.toggles, 1)
        XCTAssertTrue(vis.isFullScreen)
        vis.handleFullScreenCommand(.toggleFullScreen)
        XCTAssertEqual(fake.toggles, 2)
        XCTAssertFalse(vis.isFullScreen)
    }

    func testEscapeLeavesFullScreenOnlyWhenFullScreen() throws {
        let vis = try visModel().visualization
        vis.open()
        vis.handleFullScreenCommand(.escape)
        XCTAssertEqual(fake.toggles, 0, "Esc in a window toggled full screen")
        vis.handleFullScreenCommand(.toggleFullScreen)
        vis.handleFullScreenCommand(.escape)
        XCTAssertEqual(fake.toggles, 2)
        XCTAssertFalse(vis.isFullScreen)
    }

    func testEscapeClosesHelpAndTheListBeforeLeavingFullScreen() throws {
        let vis = try visModel().visualization
        vis.open()
        vis.handleFullScreenCommand(.toggleFullScreen)
        vis.isHelpOpen = true
        vis.isListOpen = true
        vis.handleFullScreenCommand(.escape)
        XCTAssertFalse(vis.isHelpOpen)
        XCTAssertTrue(vis.isListOpen)
        XCTAssertTrue(vis.isFullScreen)
        vis.handleFullScreenCommand(.escape)
        XCTAssertFalse(vis.isListOpen)
        XCTAssertTrue(vis.isFullScreen)
        vis.handleFullScreenCommand(.escape)
        XCTAssertFalse(vis.isFullScreen)
        XCTAssertEqual(fake.toggles, 2)
    }

    func testClosingWhileFullScreenExitsFirst() throws {
        let vis = try visModel().visualization
        vis.open()
        vis.handleFullScreenCommand(.toggleFullScreen)
        // The window leaves full screen asynchronously: the close waits for it.
        fake.reportsBack = false
        vis.close()
        XCTAssertEqual(fake.toggles, 2, "close didn't leave full screen")
        XCTAssertTrue(vis.isOpen, "closed before full screen ended")
        vis.setFullScreen(false)
        XCTAssertFalse(vis.isOpen)
        XCTAssertFalse(vis.isFullScreen)
        // Windowed, close is immediate.
        vis.open()
        vis.close()
        XCTAssertFalse(vis.isOpen)
        XCTAssertEqual(fake.toggles, 2)
    }

    /// #0245: AppKit ignores a toggle while a transition runs; the close must neither repeat nor go stale.
    func testCloseIgnoredMidTransitionIsReissuedAndClosesOnce() throws {
        let vis = try visModel().visualization
        vis.open()
        vis.handleFullScreenCommand(.toggleFullScreen)
        XCTAssertEqual(fake.toggles, 1)
        fake.reportsBack = false
        vis.close()
        vis.close()
        XCTAssertEqual(fake.toggles, 2, "a second close asked for full screen again")
        XCTAssertTrue(vis.isOpen)
        // The running transition ends still in full screen: the ignored exit is asked for again.
        vis.setFullScreen(true)
        XCTAssertEqual(fake.toggles, 3, "the ignored exit wasn't re-issued")
        XCTAssertTrue(vis.isOpen)
        vis.setFullScreen(false)
        XCTAssertFalse(vis.isOpen)
        // Nothing pending afterwards: a later full screen and exit don't close a reopened window.
        vis.open()
        vis.setFullScreen(true)
        vis.setFullScreen(false)
        XCTAssertTrue(vis.isOpen)
        XCTAssertEqual(fake.toggles, 3)
    }

    func testContextMenuTogglesFullScreen() throws {
        let vis = try visModel().visualization
        vis.open()
        let menu = VisualizationContextMenu.make(model: vis)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Enter Full Screen" } as? VisualizationCommandItem)
        XCTAssertTrue(item.isEnabled)
        _ = item.target?.perform(item.action, with: item)
        XCTAssertTrue(vis.isFullScreen)
        let exit = VisualizationContextMenu.make(model: vis).items.first { $0.title == "Exit Full Screen" }
        XCTAssertNotNil(exit)
        // Esc from the view goes through the same dispatch.
        vis.perform(.escape)
        XCTAssertFalse(vis.isFullScreen)
    }

    func testHeldCommandKeysSwallowRepeats() {
        let none: NSEvent.ModifierFlags = []
        XCTAssertTrue(VisualizationHostView.swallowsRepeat(of: .right, flags: none, isRepeat: true))
        XCTAssertTrue(VisualizationHostView.swallowsRepeat(of: .character("h"), flags: none, isRepeat: true))
        XCTAssertFalse(VisualizationHostView.swallowsRepeat(of: .right, flags: none, isRepeat: false))
        XCTAssertFalse(VisualizationHostView.swallowsRepeat(of: .character("q"), flags: none, isRepeat: true))
        XCTAssertFalse(VisualizationHostView.swallowsRepeat(of: .right, flags: .command, isRepeat: true))
    }

    func testTheWindowIsNotRestorable() throws {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        let model = makeModel(configuration)
        let controller = VisualizationWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isRestorable)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(model.visualization.fullScreenController === controller)
        window.close()
    }
}
