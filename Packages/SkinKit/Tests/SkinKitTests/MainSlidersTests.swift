import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

struct MainSlidersTests {
    private func sprite(_ name: String) -> Sprite { SkinSprites.byName[name]!.sprite }

    @Test func layoutMatchesWebampCSS() {
        let volume = MainSliders.volume
        #expect(volume.origin == CGPoint(x: 107, y: 57) && volume.size == CGSize(width: 68, height: 13) && volume.travel == 51)
        let balance = MainSliders.balance
        #expect(balance.origin == CGPoint(x: 177, y: 57) && balance.size == CGSize(width: 38, height: 13) && balance.travel == 24)
        let position = MainSliders.position
        #expect(position.origin == CGPoint(x: 16, y: 72) && position.size == CGSize(width: 248, height: 10) && position.travel == 219)
        #expect(MainSliders.frame(of: .shuffle) == .init(origin: CGPoint(x: 164, y: 89), size: CGSize(width: 47, height: 15)))
        #expect(MainSliders.frame(of: .repeatAll) == .init(origin: CGPoint(x: 210, y: 89), size: CGSize(width: 28, height: 15)))
        #expect(MainSliders.frame(of: .equalizer) == .init(origin: CGPoint(x: 219, y: 58), size: CGSize(width: 23, height: 12)))
        #expect(MainSliders.frame(of: .playlist) == .init(origin: CGPoint(x: 242, y: 58), size: CGSize(width: 23, height: 12)))
    }

    @Test func volumeFrameMatchesWebamp() {
        for v: Float in [0, 0.01, 0.02] { #expect(MainSliders.volumeFrame(v) == 0) }
        #expect(MainSliders.volumeFrame(0.5) == 13)
        #expect(MainSliders.volumeFrame(0.52) == 14)
        #expect(MainSliders.volumeFrame(1) == 27)
        var last = 0
        for step in 0...100 {
            let frame = MainSliders.volumeFrame(Float(step) / 100)
            #expect((0...27).contains(frame) && frame >= last)
            last = frame
        }
    }

    @Test func balanceFrameMatchesWebamp() {
        #expect(MainSliders.balanceFrame(0) == 0)
        #expect(MainSliders.balanceFrame(-0.0) == 0)
        #expect(MainSliders.balanceFrame(0.5) == 13)
        #expect(MainSliders.balanceFrame(-0.5) == 13)
        #expect(MainSliders.balanceFrame(1) == 27)
        #expect(MainSliders.balanceFrame(-1) == 27)
        var last = 0
        for step in 0...100 {
            let frame = MainSliders.balanceFrame(Float(step) / 100)
            #expect((0...27).contains(frame) && frame >= last)
            last = frame
        }
    }

    @Test func frameRectsStayInsideTheSheet() {
        let volume = sprite("MAIN_VOLUME_BACKGROUND")
        #expect(MainSliders.frameRect(of: volume, frame: 0) == CGRect(x: 0, y: 0, width: 68, height: 13))
        let last = MainSliders.frameRect(of: volume, frame: 27)
        #expect(last == CGRect(x: 0, y: 405, width: 68, height: 13))
        #expect(last.maxY <= 420)
        #expect(MainSliders.frameRect(of: sprite("MAIN_BALANCE_BACKGROUND"), frame: 27) == CGRect(x: 9, y: 405, width: 38, height: 13))
    }

    @Test func volumeThumbTravelsFiftyOnePixels() {
        let s = MainSliders.volume
        #expect(s.thumbX(for: 0) == 107 && s.thumbX(for: 1) == 158 && s.thumbX(for: 0.5) == 133)
        #expect(s.thumbX(for: 1) + s.thumbSize.width == 172)
        #expect(172 <= s.origin.x + s.size.width)
    }

    @Test func balanceThumbCentresAtZero() {
        let s = MainSliders.balance
        #expect(s.thumbX(for: MainSliders.fraction(forBalance: -1)) == 177)
        #expect(s.thumbX(for: MainSliders.fraction(forBalance: 0)) == 189)
        #expect(s.thumbX(for: MainSliders.fraction(forBalance: 1)) == 201)
        #expect(MainSliders.balance(forFraction: 0.5) == 0)
        #expect(MainSliders.balance(forFraction: 0) == -1 && MainSliders.balance(forFraction: 1) == 1)
    }

    @Test func positionThumbSpansTheBar() {
        let s = MainSliders.position
        #expect(s.thumbX(for: 0) == 16 && s.thumbX(for: 1) == 235)
        #expect(s.thumbX(for: 1) + s.thumbSize.width == s.origin.x + s.size.width)
    }

    @Test func pointerMapsToValueWithThumbCentred() {
        for s in [MainSliders.volume, MainSliders.balance, MainSliders.position] {
            for step in 0...100 {
                let f = Double(step) / 100
                let back = s.fraction(forPointerX: s.thumbX(for: f) + s.thumbSize.width / 2)
                #expect(abs(back - f) <= 1 / Double(s.travel))
            }
            #expect(s.fraction(forPointerX: s.origin.x - 20) == 0)
            #expect(s.fraction(forPointerX: s.origin.x + s.size.width + 20) == 1)
        }
    }

    @Test func balanceSnapsToCentreBelowTwentyFivePercent() {
        #expect(MainSliders.snappedBalance(0.24) == 0 && MainSliders.snappedBalance(-0.24) == 0)
        #expect(MainSliders.snappedBalance(0.25) == 0.25)
        #expect(MainSliders.snappedBalance(-1) == -1 && MainSliders.snappedBalance(1) == 1)
    }

    @Test func toggleSpriteNamesResolve() {
        for toggle in MainSliders.Toggle.allCases {
            for selected in [false, true] {
                for pressed in [false, true] {
                    let name = MainSliders.spriteName(toggle, selected: selected, pressed: pressed)
                    #expect(SkinSprites.byName[name] != nil, "\(name)")
                    #expect(SkinSprites.byName[name]?.sheet == "SHUFREP")
                }
            }
        }
        #expect(MainSliders.spriteName(.shuffle, selected: true, pressed: true) == "MAIN_SHUFFLE_BUTTON_SELECTED_DEPRESSED")
        #expect(MainSliders.spriteName(.repeatAll, selected: false, pressed: true) == "MAIN_REPEAT_BUTTON_DEPRESSED")
        #expect(MainSliders.spriteName(.equalizer, selected: true, pressed: true) == "MAIN_EQ_BUTTON_DEPRESSED_SELECTED")
        #expect(MainSliders.spriteName(.playlist, selected: true, pressed: false) == "MAIN_PLAYLIST_BUTTON_SELECTED")
    }
}
