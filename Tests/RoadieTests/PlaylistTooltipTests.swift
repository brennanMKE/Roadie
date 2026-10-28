import SkinKit
import XCTest

@testable import Roadie

/// The playlist editor's ADD / REM / SEL / MISC / LIST tooltips (#0227).
final class PlaylistTooltipTests: XCTestCase {
    func testEachButtonNamesItsMenu() {
        XCTAssertEqual(PlaylistLayout.Menu.add.tooltip, "ADD: Add File, Add Folder, Add URL")
        XCTAssertEqual(PlaylistLayout.Menu.remove.tooltip, "REM: Remove Selected, Crop, Remove All")
        XCTAssertEqual(PlaylistLayout.Menu.selection.tooltip, "SEL: Select All, Select None, Invert Selection")
        XCTAssertEqual(PlaylistLayout.Menu.misc.tooltip, "MISC: Misc Options, File Info, Sort List")
        XCTAssertEqual(PlaylistLayout.Menu.list.tooltip, "LIST: Load List, Save List, New List")
    }

    func testTooltipsCoverEveryEntryButRemoveMisc() throws {
        for menu in PlaylistLayout.Menu.allCases {
            let labels = try PlaylistLayout.entrySprites(menu).reversed().compactMap { sprite -> String? in
                let label = try XCTUnwrap(AXID.PL.Menu.entries[sprite]?.label, "no label for \(sprite)")
                return sprite == "PLAYLIST_REMOVE_MISC" ? nil : label
            }
            XCTAssertEqual(menu.tooltip, "\(menu.buttonName): " + labels.joined(separator: ", "), "\(menu)")
            XCTAssertFalse(menu.tooltip.contains("Remove Misc"), "\(menu)")
        }
    }
}
