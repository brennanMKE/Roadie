import Foundation
import XCTest

/// The Library window's helpers, shared by `LibraryUITests` (#0205) and `MusicAssistantUITests` (#0206).
extension RoadieUITestCase {
    /// The window's identifier is `library`; its title is "Library – <source>" (navigation title and subtitle).
    var libraryWindow: XCUIElement { roadie.app.windows["library"] }

    /// The list row (an outline row) holding `id`. The identifier lands on every element inside the row (art, title,
    /// artist), so `element(id)` is the art image.
    func libraryListRow(_ id: String) -> XCUIElement {
        roadie.app.outlineRows.containing(.any, identifier: id).firstMatch
    }

    /// Selects a Library row with a click near its right end (setup, not the click under test).
    func selectLibraryRow(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = libraryListRow(id)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row holding \(id)", file: file, line: line)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
    }

    /// Clicks a Library row's title, where a user clicks. #0205: an album row's double-click gesture covered the row's
    /// content (`FavoriteRow`'s content shape), so this click didn't select (open) the album.
    func clickLibraryTitle(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = roadie.app.staticTexts.matching(identifier: id).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no title text for \(id)", file: file, line: line)
        title.click()
    }

    /// Whether the Library window shows `text`: any element's label (search results are buttons), or a static text's
    /// value (SwiftUI puts a Text's string there). The value query is static texts only: a `value` predicate over every
    /// element type timed out and stalled the app's accessibility (run 20261029-211021-71914); label queries didn't.
    func libraryShows(_ text: String) -> Bool {
        libraryWindow.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
            || libraryWindow.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.exists
    }

    /// Whether the Library window has an element whose label or (static text) value is exactly `text`.
    func libraryShowsExactly(_ text: String) -> Bool {
        libraryWindow.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch.exists
            || libraryWindow.staticTexts.matching(NSPredicate(format: "value == %@", text)).firstMatch.exists
    }

    /// A control in the Library window by its label. The status view's `.accessibilityIdentifier("library.status")`
    /// overrides its buttons' own `library.retry` / `library.openSettings` (run 20261029-213920-81208, #0252), so
    /// they're found by title.
    func libraryControl(_ label: String) -> XCUIElement {
        libraryWindow.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A context-menu item while the menu is open: under a window (SwiftUI's context menus) or the app's menus.
    func libraryMenuItem(_ title: String) -> XCUIElement {
        let inWindows = roadie.app.windows.descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title == %@", title)).firstMatch
        if inWindows.exists { return inWindows }
        return roadie.app.menus.descendants(matching: .menuItem).matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    /// Right-clicks `id`'s row and waits for the menu (its Play item).
    func openLibraryMenu(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(id)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(id)", file: file, line: line)
        row.rightClick()
        XCTAssertTrue(
            roadie.wait { self.libraryMenuItem("Play").exists }, "right-clicking \(id) showed no menu", file: file, line: line)
    }

    /// Presses `source` (a Library row) and drags it to `target`'s centre.
    func dragLibraryRow(_ source: String, to target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // The row's first text (its title): the identifier is on every element of the row, the art image first.
        let row = roadie.app.staticTexts.matching(identifier: source).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(source)", file: file, line: line)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "no drop target \(target)", file: file, line: line)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.0, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// A screenshot kept whatever the outcome.
    func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
