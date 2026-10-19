import CoreGraphics
import SkinKit
import Testing

struct ClutterBarLayoutTests {
    @Test func clutterButtonRectsMatchWebampCSS() {
        #expect(MainWindowLayout.rect(.mainMenu) == CGRect(x: 10, y: 25, width: 8, height: 8))
        #expect(MainWindowLayout.rect(.alwaysOnTop) == CGRect(x: 10, y: 33, width: 8, height: 7))
        #expect(MainWindowLayout.rect(.fileInfo) == CGRect(x: 10, y: 40, width: 8, height: 7))
        #expect(MainWindowLayout.rect(.doubleSize) == CGRect(x: 10, y: 47, width: 8, height: 8))
        #expect(MainWindowLayout.rect(.visualizer) == CGRect(x: 10, y: 55, width: 8, height: 7))
    }

    @Test func clutterButtonsLieInsideTheClutterBar() {
        let rects = MainWindowLayout.ClutterButton.allCases.map { MainWindowLayout.rect($0) }
        for (i, rect) in rects.enumerated() {
            #expect(MainWindowLayout.clutterBar.contains(rect))
            for other in rects[(i + 1)...] {
                #expect(!rect.intersects(other))
            }
        }
    }

    @Test func clutterButtonSpritesMatchTheirRects() throws {
        for button in MainWindowLayout.ClutterButton.allCases {
            let sprite = try #require(SkinSprites.byName[MainWindowLayout.spriteName(button)]?.sprite)
            let rect = MainWindowLayout.rect(button)
            #expect(CGFloat(sprite.width) == rect.width)
            #expect(CGFloat(sprite.height) == rect.height)
        }
    }
}
