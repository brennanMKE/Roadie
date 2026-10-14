import CoreGraphics
import Testing
@testable import SkinKit

@Suite struct EQLayoutTests {
    @Test func layoutMatchesWebampCSS() {
        #expect(EQLayout.windowSize == CGSize(width: 275, height: 116))
        #expect(EQLayout.titleButtonRects == [CGRect(x: 254, y: 3, width: 9, height: 9), CGRect(x: 264, y: 3, width: 9, height: 9)])
        #expect(EQLayout.onButton == CGRect(x: 14, y: 18, width: 26, height: 12))
        #expect(EQLayout.autoButton == CGRect(x: 40, y: 18, width: 32, height: 12))
        #expect(EQLayout.presetsButton == CGRect(x: 217, y: 18, width: 44, height: 12))
        #expect(EQLayout.graph == CGRect(x: 86, y: 17, width: 113, height: 19))
        #expect(EQLayout.plus12 == CGRect(x: 45, y: 36, width: 22, height: 8))
        #expect(EQLayout.zero == CGRect(x: 45, y: 64, width: 22, height: 8))
        #expect(EQLayout.minus12 == CGRect(x: 45, y: 95, width: 22, height: 8))
        #expect(EQLayout.preampOrigin == CGPoint(x: 21, y: 38))
        #expect(EQLayout.bandOrigin(0) == CGPoint(x: 78, y: 38))
        #expect(EQLayout.bandOrigin(1) == CGPoint(x: 96, y: 38))
        #expect(EQLayout.bandOrigin(9) == CGPoint(x: 240, y: 38))
        #expect(EQLayout.bandStrip == CGRect(x: 78, y: 38, width: 176, height: 63))
        #expect(EQLayout.bandStrip.maxX == EQLayout.bandOrigin(9).x + EQLayout.bandSize.width)
    }

    @Test func valueAndGainRoundTrip() {
        #expect(EQLayout.value(forGain: 0) == 50)
        #expect(EQLayout.value(forGain: -12) == 0)
        #expect(EQLayout.value(forGain: 12) == 100)
        #expect(EQLayout.value(forGain: 6) == 75)
        #expect(EQLayout.gain(forValue: 50) == 0)
        #expect(EQLayout.gain(forValue: 0) == -12)
        #expect(EQLayout.gain(forValue: 100) == 12)
        for g in stride(from: Float(-12), through: 12, by: 0.5) {
            #expect(abs(EQLayout.gain(forValue: EQLayout.value(forGain: g)) - g) < 1e-4)
        }
        #expect(EQLayout.value(forGain: 30) == 100)
        #expect(EQLayout.value(forGain: -30) == 0)
    }

    @Test func snapMatchesWebamp() {
        #expect(EQLayout.snapped(54.9) == 50)
        #expect(EQLayout.snapped(45.1) == 50)
        #expect(EQLayout.snapped(55) == 55)
        #expect(EQLayout.snapped(45) == 45)
        #expect(EQLayout.snapped(0) == 0)
        #expect(EQLayout.snapped(100) == 100)
    }

    @Test func bandFrameMatchesBandTest() {
        #expect(EQLayout.frame(forValue: 0) == 0)
        #expect(EQLayout.frame(forValue: 50) == 14)
        #expect(EQLayout.frame(forValue: 100) == 27)
        var last = 0
        for v in stride(from: 0.0, through: 100, by: 1) {
            let f = EQLayout.frame(forValue: v)
            #expect(f >= last && (0...27).contains(f))
            last = f
        }
        let sprite = CGRect(x: 13, y: 164, width: 209, height: 129)
        #expect(EQLayout.bandFrameRect(in: sprite, frame: 0) == CGRect(x: 13, y: 164, width: 14, height: 63))
        #expect(EQLayout.bandFrameRect(in: sprite, frame: 14) == CGRect(x: 13, y: 229, width: 14, height: 63))
        let last27 = EQLayout.bandFrameRect(in: sprite, frame: 27)
        #expect(last27 == CGRect(x: 208, y: 229, width: 14, height: 63))
        #expect(last27.maxX == sprite.maxX && last27.maxY <= 293)
    }

    @Test func thumbTravelsFiftyOnePixels() {
        #expect(EQLayout.thumbY(forValue: 100) == 0)
        #expect(EQLayout.thumbY(forValue: 50) == 25)
        #expect(EQLayout.thumbY(forValue: 0) == 51)
        #expect(EQLayout.thumbY(forValue: 0) + EQLayout.thumbSize.height == EQLayout.sliderHeight)
    }

    @Test func pointerMapsToValueWithThumbCentred() {
        for v in stride(from: 0.0, through: 100, by: 1) {
            let mapped = EQLayout.value(forPointerY: EQLayout.thumbY(forValue: v) + 5.5)
            #expect(abs(mapped - v) <= 100.0 / 51)
        }
        #expect(EQLayout.value(forPointerY: -20) == 100)
        #expect(EQLayout.value(forPointerY: 90) == 0)
    }

    @Test func bandIndexFollowsTheColumns() {
        #expect(EQLayout.bandIndex(atX: 78) == 0)
        #expect(EQLayout.bandIndex(atX: 91) == 0)
        #expect(EQLayout.bandIndex(atX: 95) == 0)
        #expect(EQLayout.bandIndex(atX: 96) == 1)
        #expect(EQLayout.bandIndex(atX: 240) == 9)
        #expect(EQLayout.bandIndex(atX: 253) == 9)
        #expect(EQLayout.bandIndex(atX: 10) == 0)
        #expect(EQLayout.bandIndex(atX: 400) == 9)
    }

    @Test func spriteNamesResolve() {
        let names = [
            "EQ_ON_BUTTON", "EQ_ON_BUTTON_SELECTED", "EQ_ON_BUTTON_DEPRESSED", "EQ_ON_BUTTON_SELECTED_DEPRESSED",
            "EQ_AUTO_BUTTON", "EQ_AUTO_BUTTON_DEPRESSED", "EQ_PRESETS_BUTTON", "EQ_PRESETS_BUTTON_SELECTED",
            "EQ_SLIDER_THUMB", "EQ_SLIDER_THUMB_SELECTED", "EQ_SLIDER_BACKGROUND", "EQ_CLOSE_BUTTON", "EQ_CLOSE_BUTTON_ACTIVE",
            "EQ_MAXIMIZE_BUTTON_ACTIVE", "EQ_TITLE_BAR", "EQ_TITLE_BAR_SELECTED", "EQ_GRAPH_BACKGROUND",
            "EQ_GRAPH_LINE_COLORS", "EQ_PREAMP_LINE", "EQ_WINDOW_BACKGROUND",
        ]
        for name in names { #expect(SkinSprites.byName[name] != nil, "\(name)") }
        // Without eq_ex.bmp the shade-button pressed sprite comes from the EQMAIN fallback.
        let skin = TestSkin.make(omitting: ["EQ_EX"])
        #expect(skin.resolve("EQ_MAXIMIZE_BUTTON_ACTIVE")?.sheet == "EQMAIN")
        #expect(skin.resolve("EQ_MAXIMIZE_BUTTON_ACTIVE")?.rect == CGRect(x: 254, y: 152, width: 9, height: 9))
    }
}
