import AppKit
import SkinKit
import XCTest

@testable import Roadie

/// `MainMenuBuilder` turns `MainMenu.entries` into an `NSMenu` (#0193).
@MainActor
final class MainMenuBuilderTests: PlayerModelTestCase {
    func testBuildsEveryEntryWithTitleAndShortcut() {
        let state = MainMenuState(isEQWindowOpen: true, isRepeating: true)
        let entries = MainMenu.entries(state)
        let menu = MainMenuBuilder.menu(entries, perform: { _ in })
        assertMenu(menu, matches: entries)
    }

    func testClickingAnItemDispatchesItsCommand() throws {
        var received: [MainMenuCommand] = []
        let menu = MainMenuBuilder.menu(MainMenu.entries(MainMenuState()), perform: { received.append($0) })
        let item = try XCTUnwrap(findItem(titled: "Jump to File\u{2026}", in: menu))
        let action = try XCTUnwrap(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertEqual(received, [.jumpToFile])
    }

    /// Visualization ▸ Start/Stop Visualization calls `perform(.toggleVisualization)`, which flips the window (#0235).
    func testVisualizationSubmenuDispatchesToggle() throws {
        let model = try makeModel()
        XCTAssertFalse(model.visualization.isOpen)
        let menu = MainMenuBuilder.menu(MainMenu.entries(model.mainMenuState)) { [weak model] in model?.perform($0) }
        let item = try XCTUnwrap(findItem(titled: "Start/Stop Visualization", in: menu))
        XCTAssertEqual(item.state, .off)
        let action = try XCTUnwrap(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(model.visualization.isOpen)
        XCTAssertTrue(model.mainMenuState.isVisualizationOpen)
        NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertFalse(model.visualization.isOpen)
    }

    private func assertMenu(_ menu: NSMenu, matches entries: [MainMenuEntry], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(menu.items.count, entries.count, "item count in \(menu.title)", file: file, line: line)
        for (item, entry) in zip(menu.items, entries) {
            switch entry {
            case .separator:
                XCTAssertTrue(item.isSeparatorItem, "separator at \(item.title)", file: file, line: line)
            case .submenu(let title, let children):
                XCTAssertEqual(item.title, title, file: file, line: line)
                guard let submenu = item.submenu else {
                    XCTFail("\(title) has no submenu", file: file, line: line)
                    continue
                }
                assertMenu(submenu, matches: children, file: file, line: line)
            case .item(let model):
                XCTAssertEqual(item.title, model.title, file: file, line: line)
                XCTAssertEqual(item.state == .on, model.state == .on, "state of \(model.title)", file: file, line: line)
                XCTAssertEqual(item.isEnabled, model.isEnabled, "isEnabled of \(model.title)", file: file, line: line)
                XCTAssertEqual(item.keyEquivalent, model.shortcut?.key ?? "", "key of \(model.title)", file: file, line: line)
                if let shortcut = model.shortcut {
                    let mask = item.keyEquivalentModifierMask
                    XCTAssertEqual(mask.contains(.command), shortcut.modifiers.contains(.command), model.title, file: file, line: line)
                    XCTAssertEqual(mask.contains(.option), shortcut.modifiers.contains(.option), model.title, file: file, line: line)
                    XCTAssertEqual(mask.contains(.shift), shortcut.modifiers.contains(.shift), model.title, file: file, line: line)
                    XCTAssertEqual(mask.contains(.control), shortcut.modifiers.contains(.control), model.title, file: file, line: line)
                }
            }
        }
    }

    private func findItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title, item.submenu == nil { return item }
            if let submenu = item.submenu, let found = findItem(titled: title, in: submenu) { return found }
        }
        return nil
    }
}
