import CoreGraphics
import Testing
@testable import SkinKit

@Suite struct MainShadeLayoutTests {
    @Test func shadeLayoutMatchesWebampCSS() {
        #expect(MainShadeLayout.size == CGSize(width: 275, height: 14))
        let xs: [CGFloat] = [6, 244, 254, 264]
        #expect(MainShadeLayout.buttonRects == xs.map { CGRect(x: $0, y: 3, width: 9, height: 9) })
        #expect(MainShadeLayout.miniTimeOrigin == CGPoint(x: 127, y: 4))
        #expect(MainShadeLayout.miniTimeCellX == [1, 7, 12, 20, 25])
        #expect(MainShadeLayout.miniTimeImageWidth == 30)
        #expect(MainShadeLayout.visualizerFrame == CGRect(x: 79, y: 5, width: 76, height: 5))
        #expect(MainShadeLayout.frame(of: .previous) == CGRect(x: 169, y: 2, width: 7, height: 10))
        #expect(MainShadeLayout.frame(of: .play) == CGRect(x: 176, y: 2, width: 10, height: 10))
        #expect(MainShadeLayout.frame(of: .pause) == CGRect(x: 186, y: 2, width: 9, height: 10))
        #expect(MainShadeLayout.frame(of: .stop) == CGRect(x: 195, y: 2, width: 9, height: 10))
        #expect(MainShadeLayout.frame(of: .next) == CGRect(x: 204, y: 2, width: 10, height: 10))
        #expect(MainShadeLayout.frame(of: .eject) == CGRect(x: 215, y: 2, width: 10, height: 10))
    }

    @Test func shadePositionSliderMatchesWebampCSS() {
        let slider = MainSliders.shadePosition
        #expect(slider.origin == CGPoint(x: 226, y: 4) && slider.size == CGSize(width: 17, height: 7))
        #expect(slider.thumbSize == CGSize(width: 3, height: 7) && slider.thumbInsetY == 0 && slider.travel == 14)
        #expect(slider.thumbX(for: 0) == 226)
        #expect(slider.thumbX(for: 1) == 240)
        #expect(slider.fraction(forPointerX: 226 + 1.5) == 0)
        #expect(slider.fraction(forPointerX: 240 + 1.5) == 1)
    }

    @Test func shadePositionThumbFollowsThirds() {
        for f in [0, 0.2, 0.33] { #expect(MainSliders.shadePositionThumbName(fraction: f) == "MAIN_SHADE_POSITION_THUMB_LEFT") }
        for f in [0.34, 0.5, 0.65] { #expect(MainSliders.shadePositionThumbName(fraction: f) == "MAIN_SHADE_POSITION_THUMB") }
        for f in [0.66, 0.9, 1] { #expect(MainSliders.shadePositionThumbName(fraction: f) == "MAIN_SHADE_POSITION_THUMB_RIGHT") }
    }

    @Test func dragExclusionsCoverEveryShadeControlAndNothingElse() {
        let exclusions = MainShadeLayout.dragExclusions
        let controls: [CGRect] =
            MainShadeLayout.buttonRects + MainShadeLayout.Transport.allCases.map(MainShadeLayout.frame(of:))
            + [
                CGRect(x: 127, y: 4, width: 25, height: 6), MainShadeLayout.visualizerFrame,
                CGRect(origin: MainSliders.shadePosition.origin, size: MainSliders.shadePosition.size),
            ]
        for control in controls {
            #expect(exclusions.contains { $0.contains(control) }, "\(control)")
        }
        for point in [CGPoint(x: 30, y: 7), CGPoint(x: 60, y: 10), CGPoint(x: 160, y: 7)] {
            #expect(!exclusions.contains { $0.contains(point) }, "\(point)")
        }
        let strip = CGRect(x: 0, y: 0, width: 275, height: 14)
        #expect(exclusions.allSatisfy { strip.contains($0) })
    }
}
