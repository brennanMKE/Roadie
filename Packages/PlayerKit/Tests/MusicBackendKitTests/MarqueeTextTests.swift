import Testing
@testable import MusicBackendKit

@Suite struct MarqueeTextTests {
    private let output = OutputDevice.thisMacID

    @Test func formatsTheTrackLikeWinamp() {
        #expect(MarqueeText.track(artist: "Artist", title: "Title", duration: 225, number: 1) == "1. Artist - Title (3:45)")
        #expect(MarqueeText.track(artist: "", title: "Title", duration: 225, number: 1) == "1. Title (3:45)")
        #expect(MarqueeText.track(artist: nil, title: "Title", duration: 0, number: 1) == "1. Title")
        #expect(MarqueeText.track(artist: "Artist", title: "Title", duration: nil, number: nil) == "Artist - Title")
        #expect(MarqueeText.time(5) == "0:05")
        #expect(MarqueeText.time(65) == "1:05")
        #expect(MarqueeText.time(3725) == "62:05")
        #expect(MarqueeText.time(3599.9) == "59:59")
    }

    /// SkinKit cannot import MusicBackendKit, so `MainWindowState.idle` repeats this literal; RenderingTests pins it there.
    @Test func idleTextIsTheLiteralSkinKitsIdleStateRepeats() {
        #expect(MarqueeText.idle == "SkinAmp")
    }

    @Test func formatsSliderFocusTextLikeWebamp() {
        #expect(MarqueeText.volume(0.57) == "Volume: 57%")
        #expect(MarqueeText.volume(0) == "Volume: 0%")
        #expect(MarqueeText.balance(0) == "Balance: Center")
        #expect(MarqueeText.balance(-0.4) == "Balance: 40% Left")
        #expect(MarqueeText.balance(1) == "Balance: 100% Right")
        #expect(MarqueeText.seek(fraction: 0.375, duration: 225) == "Seek to: 1:24/3:45 (37%)")
    }

    @Test func displaysIdleBufferingAndTrack() {
        for state in [NowPlaying.State.stopped, .loading, .playing, .paused] {
            #expect(MarqueeText.display(NowPlaying(output: output, state: state), number: nil) == MarqueeText.idle)
        }
        func local(_ state: NowPlaying.State) -> NowPlaying {
            NowPlaying(output: output, state: state, title: "Two", artist: "B", duration: 61)
        }
        for state in [NowPlaying.State.stopped, .loading, .playing, .paused] {
            #expect(MarqueeText.display(local(state), number: 2) == "2. B - Two (1:01)")
        }
        var remote = local(.loading)
        remote.item = MediaID(.track, "42")
        #expect(MarqueeText.display(remote, number: 2) == MarqueeText.buffering)
        remote.state = .playing
        #expect(MarqueeText.display(remote, number: 2) == "2. B - Two (1:01)")
    }


    @Test func formatsEqualizerTextLikeWebamp() {
        #expect(MarqueeText.equalizer(bandHz: 60, gain: 3.4) == "EQ: 60HZ +3.4 DB")
        #expect(MarqueeText.equalizer(bandHz: 1000, gain: -12) == "EQ: 1KHZ -12 DB")
        #expect(MarqueeText.equalizer(bandHz: 12000, gain: 0) == "EQ: 12KHZ 0 DB")
        #expect(MarqueeText.equalizer(bandHz: nil, gain: 2) == "EQ: Preamp +2 DB")
        #expect(MarqueeText.equalizer(bandHz: 170, gain: -0.04) == "EQ: 170HZ 0 DB")
        #expect(MarqueeText.equalizer(bandHz: 310, gain: -1.25) == "EQ: 310HZ -1.2 DB")
    }
}
