import CoreGraphics
import Foundation
import Testing
@testable import SkinKit

struct RenderingTests {
    private let skin = TestSkin.make()

    private func expectPixel(
        _ image: CGImage, _ x: Int, _ y: Int, _ sprite: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            TestBitmaps.pixel(image, x: x, y: y) == TestSkin.color(of: sprite),
            "pixel (\(x), \(y)) should be \(sprite)", sourceLocation: sourceLocation)
    }

    private func playing(_ configure: (inout MainWindowState) -> Void = { _ in }) -> MainWindowState {
        var state = MainWindowState.webampScreenshot
        configure(&state)
        return state
    }

    @Test func rendersHeadless() {
        let image = MainWindowRenderer.render(skin: skin, state: .idle)
        #expect(image.width == 275 && image.height == 116)
        #expect(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
        #expect(image.alphaInfo == .premultipliedLast)
        let base = MainWindowRenderer.renderBase(skin: skin, focused: true)
        #expect(base.width == 275 && base.height == 116)
        #expect(MainWindowRenderer.render(skin: skin, state: .idle, scale: 0).width == 275)   // clamped to 1
    }

    @Test func layoutMatchesWebampCSS() {
        #expect(MainWindowLayout.size == CGSize(width: 275, height: 116))
        #expect(MainWindowLayout.shadeSize == CGSize(width: 275, height: 14))
        #expect(MainWindowLayout.titleBar == CGRect(x: 0, y: 0, width: 275, height: 14))
        #expect(MainWindowLayout.TitleButton.allCases.map { MainWindowLayout.rect($0).minX } == [6, 244, 254, 264])
        for button in MainWindowLayout.TitleButton.allCases {
            #expect(MainWindowLayout.rect(button).size == CGSize(width: 9, height: 9))
            #expect(MainWindowLayout.rect(button).minY == 3)
        }
        #expect(MainWindowLayout.clutterBar == CGRect(x: 10, y: 22, width: 8, height: 43))
        #expect(MainWindowLayout.workIndicator == CGRect(x: 24, y: 28, width: 3, height: 9))
        #expect(MainWindowLayout.playIndicator == CGPoint(x: 26, y: 28))
        #expect(MainWindowLayout.timeHitArea == CGRect(x: 39, y: 26, width: 59, height: 13))
        #expect(MainWindowLayout.digitXs == [48, 60, 78, 90])
        #expect(MainWindowLayout.digitY == 26)
        #expect(MainWindowLayout.visualizer == CGRect(x: 24, y: 43, width: 76, height: 16))
        #expect(MainWindowLayout.marquee == CGRect(x: 111, y: 27, width: 154, height: 6))
        #expect(MainWindowLayout.marqueeHitArea == CGRect(x: 111, y: 24, width: 154, height: 12))
        #expect(MainWindowLayout.kbps == CGPoint(x: 111, y: 43))
        #expect(MainWindowLayout.khz == CGPoint(x: 156, y: 43))
        #expect(MainWindowLayout.mono == CGPoint(x: 212, y: 41))
        #expect(MainWindowLayout.stereo == CGPoint(x: 239, y: 41))
        #expect(MainWindowLayout.Transport.allCases.map { MainWindowLayout.rect($0).minX } == [16, 39, 62, 85, 108, 136])
        #expect(MainWindowLayout.rect(.play) == CGRect(x: 39, y: 88, width: 23, height: 18))
        #expect(MainWindowLayout.rect(.next) == CGRect(x: 108, y: 88, width: 22, height: 18))   // Webamp clips the 23 px sprite
        #expect(MainWindowLayout.rect(.eject) == CGRect(x: 136, y: 89, width: 22, height: 16))
        #expect(MainWindowLayout.spriteName(.play, pressed: false) == "MAIN_PLAY_BUTTON")
        #expect(MainWindowLayout.spriteName(.eject, pressed: true) == "MAIN_EJECT_BUTTON_ACTIVE")
        for control in MainWindowLayout.Transport.allCases {
            #expect(SkinSprites.byName[MainWindowLayout.spriteName(control, pressed: false)] != nil)
            #expect(SkinSprites.byName[MainWindowLayout.spriteName(control, pressed: true)] != nil)
        }
    }

    @Test func baseLayersAtWebampPositions() {
        let focused = MainWindowRenderer.renderBase(skin: skin, focused: true)
        let unfocused = MainWindowRenderer.renderBase(skin: skin, focused: false)
        expectPixel(focused, 0, 20, "MAIN_WINDOW_BACKGROUND")
        expectPixel(focused, 100, 5, "MAIN_TITLE_BAR_SELECTED")
        expectPixel(unfocused, 100, 5, "MAIN_TITLE_BAR")
        expectPixel(focused, 10, 22, "MAIN_CLUTTER_BAR_BACKGROUND")
        expectPixel(focused, 16, 88, "MAIN_PREVIOUS_BUTTON")
        expectPixel(focused, 39, 88, "MAIN_PLAY_BUTTON")
        expectPixel(focused, 62, 88, "MAIN_PAUSE_BUTTON")
        expectPixel(focused, 85, 88, "MAIN_STOP_BUTTON")
        expectPixel(focused, 108, 88, "MAIN_NEXT_BUTTON")
        expectPixel(focused, 136, 89, "MAIN_EJECT_BUTTON")
        expectPixel(focused, 129, 90, "MAIN_NEXT_BUTTON")
        expectPixel(focused, 130, 90, "MAIN_WINDOW_BACKGROUND")   // the sprite's 23rd column is clipped
        // Title-bar buttons are not drawn until clicked.
        expectPixel(focused, 248, 7, "MAIN_TITLE_BAR_SELECTED")
        // Dynamic content is not part of the base.
        expectPixel(focused, 26, 28, "MAIN_WINDOW_BACKGROUND")
    }

    @Test func statusLayerFollowsState() {
        let state = playing()
        let image = MainWindowRenderer.render(skin: skin, state: state)
        expectPixel(image, 24, 28, "MAIN_NOT_WORKING_INDICATOR")
        expectPixel(image, 27, 28, "MAIN_PLAYING_INDICATOR")
        expectPixel(image, 48, 26, "DIGIT_0")
        expectPixel(image, 60, 26, "DIGIT_0")
        expectPixel(image, 78, 26, "DIGIT_0")
        expectPixel(image, 90, 26, "DIGIT_3")
        expectPixel(image, 38, 32, "NO_MINUS_SIGN")
        expectPixel(image, 239, 41, "MAIN_STEREO_SELECTED")
        expectPixel(image, 212, 41, "MAIN_MONO")

        let paused = MainWindowRenderer.render(skin: skin, state: playing { $0.status.transport = .paused })
        expectPixel(paused, 27, 28, "MAIN_PAUSED_INDICATOR")
        expectPixel(paused, 24, 28, "MAIN_WINDOW_BACKGROUND")   // no work indicator while paused

        let loading = MainWindowRenderer.render(skin: skin, state: playing { $0.status.transport = .loading })
        expectPixel(loading, 24, 28, "MAIN_WORKING_INDICATOR")
        expectPixel(loading, 27, 28, "MAIN_WINDOW_BACKGROUND")   // the 3 px crop, and no play indicator

        let stopped = MainWindowRenderer.render(skin: skin, state: .idle)
        expectPixel(stopped, 27, 28, "MAIN_STOPPED_INDICATOR")
        expectPixel(stopped, 48, 26, "MAIN_WINDOW_BACKGROUND")
        expectPixel(stopped, 38, 32, "MAIN_WINDOW_BACKGROUND")

        let mono = MainWindowRenderer.render(skin: skin, state: playing { $0.status.channels = 1 })
        expectPixel(mono, 212, 41, "MAIN_MONO_SELECTED")
        expectPixel(mono, 239, 41, "MAIN_STEREO")

        let remaining = MainWindowRenderer.render(skin: skin, state: playing { $0.status.timeMode = .remaining })
        expectPixel(remaining, Int(skin.minusFrame.minX), Int(skin.minusFrame.minY), "MINUS_SIGN")
    }

    @Test func mediaInfoAndMarqueeUseTheTextFont() {
        let image = MainWindowRenderer.render(skin: skin, state: playing())
        expectPixel(image, 111, 43, "CHARACTER_49")   // "128"
        expectPixel(image, 156, 43, "CHARACTER_52")   // "44"
        expectPixel(image, 111, 27, "CHARACTER_49")   // "1. DJ Mike..."
        expectPixel(image, 116, 27, "CHARACTER_46")

        let long = String(repeating: "1.", count: 20)
        let atStart = MainWindowRenderer.render(skin: skin, state: playing { $0.marqueeText = long })
        expectPixel(atStart, 111, 27, "CHARACTER_49")
        let stepped = MainWindowRenderer.render(skin: skin, state: playing { $0.marqueeText = long; $0.marqueeStep = 1 })
        expectPixel(stepped, 111, 27, "CHARACTER_46")   // what was at (116, 27)
        let dragged = MainWindowRenderer.render(skin: skin, state: playing { $0.marqueeText = long; $0.marqueePixels = 5 })
        expectPixel(dragged, 111, 27, "CHARACTER_46")
        // The strip is clipped to its 154x6 window.
        expectPixel(stepped, 265, 27, "MAIN_WINDOW_BACKGROUND")
        expectPixel(stepped, 111, 33, "MAIN_WINDOW_BACKGROUND")
    }

    @Test func slidersAndTogglesFollowState() {
        let image = MainWindowRenderer.render(skin: skin, state: playing())
        let volumeX = Int(MainSliders.volume.thumbX(for: 0.78))
        #expect(volumeX == 147)
        expectPixel(image, volumeX, 58, "MAIN_VOLUME_THUMB")
        expectPixel(image, 107, 57, "MAIN_VOLUME_BACKGROUND")
        expectPixel(image, 189, 58, "MAIN_BALANCE_THUMB")   // centred: 177 + 12
        expectPixel(image, 177, 57, "MAIN_BALANCE_BACKGROUND")
        expectPixel(image, 147, 72, "MAIN_POSITION_SLIDER_THUMB")   // 0.6: 16 + round(0.6 * 219)
        expectPixel(image, 146, 72, "MAIN_POSITION_SLIDER_BACKGROUND")
        expectPixel(image, 164, 89, "MAIN_SHUFFLE_BUTTON_SELECTED")
        expectPixel(image, 210, 89, "MAIN_REPEAT_BUTTON_SELECTED")
        expectPixel(image, 219, 58, "MAIN_EQ_BUTTON_SELECTED")
        expectPixel(image, 242, 58, "MAIN_PLAYLIST_BUTTON_SELECTED")

        let off = MainWindowRenderer.render(skin: skin, state: playing {
            $0.shuffle = false; $0.repeatOn = false; $0.eqOpen = false; $0.playlistOpen = false
            $0.position = nil; $0.volume = 0; $0.balance = -1
        })
        expectPixel(off, 164, 89, "MAIN_SHUFFLE_BUTTON")
        expectPixel(off, 210, 89, "MAIN_REPEAT_BUTTON")
        expectPixel(off, 219, 58, "MAIN_EQ_BUTTON")
        expectPixel(off, 242, 58, "MAIN_PLAYLIST_BUTTON")
        expectPixel(off, 147, 72, "MAIN_POSITION_SLIDER_BACKGROUND")   // nil hides the thumb
        expectPixel(off, 107, 58, "MAIN_VOLUME_THUMB")                 // volume 0 puts it at the left end
        expectPixel(off, 177, 58, "MAIN_BALANCE_THUMB")                // full left
    }

    @Test func visualizerDrawsBackgroundWhenSilent() {
        let colors = skin.visColors
        let silent = MainWindowRenderer.render(skin: skin, state: playing())
        #expect(TestBitmaps.pixel(silent, x: 24, y: 43) == colors[0])
        #expect(TestBitmaps.pixel(silent, x: 24, y: 44) == colors[1])   // grid dot
        let off = MainWindowRenderer.render(skin: skin, state: playing { $0.visualizer = .off })
        expectPixel(off, 24, 43, "MAIN_WINDOW_BACKGROUND")

        // A full-height first column at 1x sits 2 rows lower (pushDown), so its top shows bar colour 0 + offset.
        let bars = MainWindowRenderer.render(
            skin: skin, state: playing { $0.visualizer = .spectrum(heights: [16] + [Int](repeating: 0, count: 74), peaks: []) })
        #expect(TestBitmaps.pixel(bars, x: 24, y: 59) != colors[0])
        let scope = MainWindowRenderer.render(
            skin: skin, state: playing { $0.visualizer = .oscilloscope([Float](repeating: 0, count: 75)) })
        // Row 7, pushed down 2.
        #expect(TestBitmaps.pixel(scope, x: 24, y: 43 + 7 + 2) == colors[18])
    }

    @Test func regionClipLeavesOutsideTransparent() {
        let polygon: SkinRegion.Polygon = [
            .init(x: 10, y: 0), .init(x: 275, y: 0), .init(x: 275, y: 116), .init(x: 0, y: 116), .init(x: 0, y: 10), .init(x: 10, y: 10),
        ]
        let shaped = TestSkin.make(region: SkinRegion(sections: ["normal": [polygon]]))
        let clipped = MainWindowRenderer.render(skin: shaped, state: .idle, clipToRegion: true)
        #expect(TestSkin.rgba(clipped, x: 0, y: 0)[3] == 0)
        #expect(TestSkin.rgba(clipped, x: 9, y: 9)[3] == 0)
        #expect(TestSkin.rgba(clipped, x: 10, y: 0)[3] == 255)
        #expect(TestSkin.rgba(clipped, x: 0, y: 20)[3] == 255)
        let unclipped = MainWindowRenderer.render(skin: shaped, state: .idle)
        #expect(TestSkin.rgba(unclipped, x: 0, y: 0)[3] == 255)
        expectPixel(unclipped, 0, 0, "MAIN_TITLE_BAR_SELECTED")
        // A skin without a region ignores the flag.
        #expect(TestSkin.rgba(MainWindowRenderer.render(skin: skin, state: .idle, clipToRegion: true), x: 0, y: 0)[3] == 255)
    }

    @Test func fullEqualsBasePlusDynamic() {
        let state = MainWindowState.webampScreenshot
        let full = MainWindowRenderer.render(skin: skin, state: state)
        let base = MainWindowRenderer.renderBase(skin: skin, focused: state.focused)
        let layered = MainWindowRenderer.renderDynamic(over: base, skin: skin, state: state)
        #expect(TestSkin.bytes(of: full) == TestSkin.bytes(of: layered))
        let scaledBase = MainWindowRenderer.renderBase(skin: skin, focused: true, scale: 2)
        #expect(scaledBase.width == 550 && scaledBase.height == 232)
        #expect(
            TestSkin.bytes(of: MainWindowRenderer.render(skin: skin, state: state, scale: 2))
                == TestSkin.bytes(of: MainWindowRenderer.renderDynamic(over: scaledBase, skin: skin, state: state, scale: 2)))
    }

    @Test func scaleTwoIsNearestNeighbour() {
        let state = MainWindowState.webampScreenshot
        let one = TestSkin.bytes(of: MainWindowRenderer.render(skin: skin, state: state, scale: 1))
        let twoImage = MainWindowRenderer.render(skin: skin, state: state, scale: 2)
        #expect(twoImage.width == 550 && twoImage.height == 232)
        let two = TestSkin.bytes(of: twoImage)
        var mismatches = 0
        for y in 0..<116 {
            for x in 0..<275 {
                let source = (y * 275 + x) * 4
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let target = ((2 * y + dy) * 550 + 2 * x + dx) * 4
                        if Array(one[source..<source + 4]) != Array(two[target..<target + 4]) { mismatches += 1 }
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func drawIntoCallerContextAtOrigin() {
        let context = CGContext(
            data: nil, width: 275, height: 232, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 232)
        context.scaleBy(x: 1, y: -1)
        MainWindowRenderer.draw(into: context, at: CGPoint(x: 0, y: 116), skin: skin, state: .idle, scale: 1, clipToRegion: false)
        let image = context.makeImage()!
        expectPixel(image, 0, 116 + 20, "MAIN_WINDOW_BACKGROUND")
        expectPixel(image, 100, 116 + 5, "MAIN_TITLE_BAR_SELECTED")
        #expect(TestSkin.rgba(image, x: 0, y: 0) == [0, 0, 0, 0])
        #expect(TestSkin.rgba(image, x: 0, y: 115) == [0, 0, 0, 0])
        // The caller's CTM survives the call.
        #expect(context.ctm == CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 232))
    }

    @Test func missingSheetsNeverTrap() {
        let onlyMain = TestSkin.make(omitting: Set(SkinSprites.sheets.keys).subtracting(["MAIN"]))
        let image = MainWindowRenderer.render(skin: onlyMain, state: .webampScreenshot)
        #expect(image.width == 275)
        expectPixel(image, 39, 88, "MAIN_WINDOW_BACKGROUND")
        expectPixel(image, 0, 0, "MAIN_WINDOW_BACKGROUND")

        let nothing = TestSkin.make(omitting: Set(SkinSprites.sheets.keys))
        let dark = TestSkin.rgba(MainWindowRenderer.render(skin: nothing, state: .webampScreenshot), x: 0, y: 0)
        #expect(dark[3] == 255)
        #expect(dark[0] == dark[1] && dark[1] == dark[2] && dark[0] < 40 && dark[0] > 0)
        _ = MainWindowRenderer.renderBase(skin: nothing, focused: false)
    }

    @Test func pngRoundTrips() throws {
        let image = MainWindowRenderer.render(skin: skin, state: .webampScreenshot)
        let data = try #require(PNGWriter.data(image))
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        let url = FileManager.default.temporaryDirectory.appending(path: "skinkit-png-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PNGWriter.write(image, to: url)
        let back = try #require(PNGWriter.read(url))
        #expect(back.width == image.width && back.height == image.height)
        for (x, y) in [(0, 0), (100, 5), (48, 26), (147, 72), (274, 115)] {
            #expect(TestBitmaps.pixel(back, x: x, y: y) == TestBitmaps.pixel(image, x: x, y: y))
        }
        #expect(PNGWriter.read(url.appending(path: "missing")) == nil)
    }

    // MARK: ImageDiff

    /// A width x height image of one colour; `patches` overwrite pixels (nil = transparent).
    private func solid(width: Int, height: Int, _ fill: [UInt8] = [10, 20, 30, 255], patches: [(Int, Int, [UInt8]?)] = []) -> CGImage {
        var bytes = [UInt8]()
        for _ in 0..<(width * height) { bytes += fill }
        for (x, y, color) in patches {
            let i = (y * width + x) * 4
            bytes.replaceSubrange(i..<i + 4, with: color ?? [0, 0, 0, 0])
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    @Test func imageDiffCountsSkipsCropsAndIgnores() {
        let ours = solid(width: 10, height: 10)
        var identical = ImageDiff.Result()
        identical.compared = 100
        #expect(ImageDiff.compare(ours: ours, reference: ours) == identical)

        // k changed pixels report k; small changes count as differing but stay within the tolerance.
        let changed = solid(width: 10, height: 10, patches: [(1, 1, [200, 20, 30, 255]), (2, 2, [0, 0, 0, 255]), (3, 3, [11, 20, 30, 255])])
        let result = ImageDiff.compare(ours: ours, reference: changed, tolerance: 2)
        #expect(result.compared == 100)
        #expect(result.differing == 3)
        #expect(result.beyondTolerance == 2)
        #expect(result.skippedTransparent == 0)

        // Transparent reference pixels are skipped.
        let holes = solid(width: 10, height: 10, patches: [(0, 0, nil), (1, 0, nil), (2, 0, nil), (3, 0, nil)])
        let skipped = ImageDiff.compare(ours: ours, reference: holes)
        #expect(skipped.skippedTransparent == 4 && skipped.compared == 96 && skipped.differing == 0)

        // A taller reference is cropped to its top rows.
        let tall = solid(width: 10, height: 30, patches: [(5, 15, [255, 255, 255, 255]), (0, 29, [255, 255, 255, 255])])
        #expect(ImageDiff.compare(ours: ours, reference: tall).differing == 0)
        let tallTop = solid(width: 10, height: 30, patches: [(5, 9, [255, 255, 255, 255])])
        #expect(ImageDiff.compare(ours: ours, reference: tallTop).differing == 1)

        // A change inside an ignored rect counts in `differing` but not in the OutsideIgnored pair.
        let both = solid(width: 10, height: 10, patches: [(1, 1, [200, 20, 30, 255]), (8, 8, [200, 20, 30, 255])])
        let ignored = ImageDiff.compare(ours: ours, reference: both, ignoring: [CGRect(x: 0, y: 0, width: 4, height: 4)])
        #expect(ignored.differing == 2 && ignored.differingOutsideIgnored == 1)
        #expect(ignored.beyondTolerance == 2 && ignored.beyondToleranceOutsideIgnored == 1)

        let diff = ImageDiff.diffImage(ours: ours, reference: both)
        #expect(TestSkin.rgba(diff, x: 1, y: 1) == [255, 0, 255, 255])
        #expect(TestSkin.rgba(diff, x: 5, y: 5) == [10, 20, 30, 255])
    }

    // MARK: Presets and options

    @Test func presetsMatchWebampAndIdle() {
        let webamp = MainWindowState.webampScreenshot
        #expect(webamp.status.transport == .playing)
        #expect(webamp.status.timeMode == .elapsed)
        #expect(webamp.status.elapsed == 3 && webamp.status.duration == 5)
        #expect(webamp.status.bitrateKbps == 128 && webamp.status.sampleRate == 44100 && webamp.status.channels == 2)
        #expect(webamp.marqueeText == "1. DJ Mike Llama - Llama Whipping Intro (0:05)")
        #expect(webamp.marqueeStep == 0 && webamp.marqueePixels == 0)
        #expect(webamp.focused)
        #expect(webamp.volume == 0.78 && webamp.balance == 0)
        #expect(webamp.position == 0.6)
        #expect(webamp.shuffle && webamp.repeatOn && webamp.eqOpen && webamp.playlistOpen)
        #expect(webamp.visualizer == .spectrum(heights: [], peaks: []))

        let idle = MainWindowState.idle
        #expect(idle.status.transport == .stopped)
        #expect(idle.marqueeText == "SkinAmp")   // MarqueeText.idle; MusicBackendKitTests pins the same literal
        #expect(idle.focused && !idle.shuffle && !idle.repeatOn && !idle.eqOpen && !idle.playlistOpen)
        #expect(idle.visualizer == .off)
    }

    @Test func skintoolOptionsParse() throws {
        let full = try SkintoolOptions.parse(
            ["--png", "out", "--state", "idle", "--scale", "2", "--no-region", "-v", "skin.wsz"]).get()
        #expect(full.png == "out" && full.state == .idle && full.scale == 2 && full.noRegion && full.verbose)
        #expect(full.input == "skin.wsz" && full.compare == nil)

        let compared = try SkintoolOptions.parse(["--png", "out", "--compare", "ref", "Skins"]).get()
        #expect(compared.compare == "ref" && compared.state == .webamp && compared.scale == 1 && !compared.noRegion)

        let bare = try SkintoolOptions.parse(["skin.wsz"]).get()
        #expect(bare == SkintoolOptions(input: "skin.wsz"))
        #expect(bare.png == nil && !bare.verbose)
        #expect(try SkintoolOptions.parse(["--verbose", "skin.wsz"]).get().verbose)

        let bad: [[String]] = [
            ["--png"], ["--png", "out"], ["--png", "-v", "skin.wsz"], ["--png", "out", "--state", "foo", "skin.wsz"],
            ["--png", "out", "--scale", "0", "skin.wsz"], ["--png", "out", "--scale", "x", "skin.wsz"],
            ["--png", "out", "--bogus", "skin.wsz"], [], ["a.wsz", "b.wsz"], ["--state", "idle", "skin.wsz"],
            ["--png", "out", "--scale", "2", "--compare", "ref", "skin.wsz"],
        ]
        for arguments in bad {
            if case .success = SkintoolOptions.parse(arguments) { Issue.record("expected a usage error for \(arguments)") }
        }
    }
}
