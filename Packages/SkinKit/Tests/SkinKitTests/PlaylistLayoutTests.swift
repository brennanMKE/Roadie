import CoreGraphics
import Testing
@testable import SkinKit

@Suite struct PlaylistLayoutTests {
    private func layout(_ w: Int, _ h: Int) -> PlaylistLayout { PlaylistLayout(steps: .init(width: w, height: h)) }

    @Test func sizeGrowsInWinampSteps() {
        #expect(layout(0, 0).size == CGSize(width: 275, height: 116))
        #expect(layout(1, 2).size == CGSize(width: 300, height: 174))
        #expect(PlaylistLayout.steps(forPixelSize: CGSize(width: 300, height: 174)) == .init(width: 1, height: 2))
        #expect(PlaylistLayout.steps(forPixelSize: CGSize(width: 10, height: 10)) == .zero)
    }

    @Test func topRowTilesTheWholeWidth() {
        for w in 0...5 {
            let l = layout(w, 0)
            for selected in [false, true] {
                let row = l.topRow(selected: selected)
                var x: CGFloat = 0
                for piece in row {
                    #expect(piece.rect.minX == x)
                    #expect(piece.rect.height == 20)
                    x = piece.rect.maxX
                }
                #expect(x == l.size.width)
                #expect(row.first?.rect.width == 25)
                #expect(row.last?.rect.width == 25)
                #expect(row.first { $0.sprite.hasPrefix("PLAYLIST_TITLE_BAR") }?.rect.width == 100)
                let spacers = row.filter { $0.rect.width == 12 || $0.rect.width == 13 }
                #expect(spacers.count == (w % 2 == 0 ? 2 : 0))
                let fills = row.filter { $0.tiled && $0.rect.width != 12 && $0.rect.width != 13 }
                #expect(fills.count == 2)
                #expect(fills[0].rect.width == fills[1].rect.width)
                #expect(fills[0].rect.width.truncatingRemainder(dividingBy: 25) == 0)
                #expect(row.allSatisfy { SkinSprites.byName[$0.sprite] != nil })
                #expect(row.allSatisfy { $0.sprite.hasSuffix("_SELECTED") == selected })
            }
        }
        #expect(layout(0, 0).topRow(selected: true).first { $0.sprite == "PLAYLIST_TITLE_BAR_SELECTED" }?.rect.minX == 87)
    }

    @Test func bottomRowAndVisualizer() {
        let l = layout(3, 1)
        let row = l.bottomRow
        #expect(row[1].sprite == "PLAYLIST_BOTTOM_LEFT_CORNER")
        #expect(row[1].rect == CGRect(x: 0, y: 145 - 38, width: 125, height: 38))
        #expect(row[2].rect == CGRect(x: 350 - 150, y: 107, width: 150, height: 38))
        #expect(row[0].rect == CGRect(x: 0, y: 107, width: 350, height: 38))
        #expect(layout(2, 0).visualizerBackground == nil)
        #expect(l.visualizerBackground == CGRect(x: 350 - 225, y: 145 - 38, width: 75, height: 38))
    }

    @Test func trackAreaAndVisibleRows() {
        for h in 0...3 {
            let l = layout(1, h)
            #expect(l.trackArea == CGRect(x: 12, y: 23, width: l.size.width - 32, height: 52 + 29 * CGFloat(h)))
            #expect(l.visibleRows == [4, 6, 8, 11][h])
        }
        #expect(layout(0, 0).leftTile.rect == CGRect(x: 0, y: 20, width: 12, height: 58))
        #expect(layout(2, 1).rightTile.rect == CGRect(x: 325 - 20, y: 20, width: 20, height: 87))
    }

    @Test func scrollBarGeometry() {
        let l = layout(1, 1)
        #expect(l.scrollTrack == CGRect(x: 300 - 15, y: 20, width: 8, height: 87))
        #expect(l.scrollHandleY(value: 0) == 20)
        #expect(l.scrollHandleY(value: 1) == CGFloat(20 + 87 - 18))
        #expect(l.scrollHandleY(value: 0.5) == CGFloat(20 + 34))   // floor(69 * 0.5)
        #expect(l.scrollValue(forPointerY: -100, grabOffset: 9) == 0)
        #expect(l.scrollValue(forPointerY: 1000, grabOffset: 9) == 1)
        #expect(l.scrollValue(forPointerY: 20 + 9 + 34.5, grabOffset: 9) == 0.5)
    }

    @Test func buttonsAndDisplaysFollowTheCSS() {
        let l = layout(0, 0)
        let (w, h): (CGFloat, CGFloat) = (275, 116)
        #expect(l.menuButton(.add) == CGRect(x: 14, y: h - 30, width: 22, height: 18))
        #expect(l.menuButton(.remove).minX == 43)
        #expect(l.menuButton(.selection).minX == 72)
        #expect(l.menuButton(.misc).minX == 101)
        #expect(l.menuButton(.list).minX == w - 44)
        #expect(l.closeButton == CGRect(x: w - 11, y: 3, width: 9, height: 9))
        #expect(l.shadeButton == CGRect(x: w - 21, y: 3, width: 9, height: 9))
        #expect(l.resizeTarget == CGRect(x: w - 20, y: h - 20, width: 20, height: 20))
        #expect(l.scrollUpButton == CGRect(x: w - 15, y: h - 36, width: 8, height: 5))
        #expect(l.scrollDownButton == CGRect(x: w - 15, y: h - 30, width: 8, height: 5))
        #expect(l.runningTimeOrigin == CGPoint(x: w - 143, y: h - 28))
        #expect(l.miniTimeOrigin == CGPoint(x: w - 84, y: h - 15))
        #expect(PlaylistLayout.miniTimeCellXs == [1, 7, 12, 20, 25])
        #expect(l.actionButtons.count == 6)
        #expect(l.actionButtons[0] == CGRect(x: w - 147, y: h - 16, width: 10, height: 10))
        #expect(l.actionButtons[5] == CGRect(x: w - 97, y: h - 16, width: 10, height: 10))
        // The buttons follow the right edge when the window grows.
        #expect(layout(2, 1).closeButton.minX == CGFloat(325 - 11))
        #expect(layout(2, 1).menuButton(.add).minX == 14)
    }

    @Test func menuEntriesStackAboveTheButtonWithTheBar() {
        let l = layout(0, 0)
        let add = l.menuEntries(.add)
        #expect(add.count == 3)
        #expect(add.last?.rect == l.menuButton(.add))
        #expect(add.first?.rect.minY == l.menuButton(.add).minY - 36)
        let bar = l.menuBar(.add)
        #expect(bar.sprite == "PLAYLIST_ADD_MENU_BAR")
        #expect(bar.rect == CGRect(x: 11, y: 116 - 66, width: 3, height: 54))
        #expect(l.menuEntries(.remove).count == 4)
        #expect(l.menuBar(.remove).rect.height == 72)
        for menu in PlaylistLayout.Menu.allCases {
            #expect(SkinSprites.byName[l.menuBar(menu).sprite] != nil)
            for entry in l.menuEntries(menu) {
                #expect(SkinSprites.byName[entry.sprite] != nil)
                #expect(SkinSprites.byName[entry.sprite + "_SELECTED"] != nil)
            }
        }
    }

    @Test func resizeRoundsLikeJavaScript() {
        let start = PlaylistLayout.Steps(width: 1, height: 1)
        #expect(PlaylistLayout.steps(from: start, draggedBy: CGSize(width: 12, height: 14)) == start)
        #expect(PlaylistLayout.steps(from: start, draggedBy: CGSize(width: 13, height: 15)) == .init(width: 2, height: 2))
        #expect(PlaylistLayout.steps(from: start, draggedBy: CGSize(width: -12.5, height: 0)) == start)
        #expect(PlaylistLayout.steps(from: start, draggedBy: CGSize(width: -300, height: -300)) == .zero)
    }
}
