import MusicBackendKit
import SkinKit
import SwiftUI

/// The time, kbps/kHz, mono/stereo and play-indicator layer of the main window. Everything is in skin
/// pixels from Webamp's css/main-window.css; the logic lives in `MainWindowStatus`.
struct MainWindowStatusLayer: View {
    let skin: Skin
    let status: MainWindowStatus
    let toggleTimeMode: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let indicator = status.indicator {
                SpriteImage(skin: skin, name: indicator).offset(x: 26, y: 28)
            }
            if let work = status.workIndicator {
                // The sprite is listed 9 wide but Webamp draws 3 px.
                SpriteImage(skin: skin, name: work)
                    .frame(width: 3, height: 9, alignment: .topLeading)
                    .clipped()
                    .offset(x: 24, y: 28)
            }
            if status.showsTime {
                if status.blinksTime {
                    BlinkingView { time }
                } else {
                    time
                }
            }
            mediaInfo
        }
    }

    private var time: some View {
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: status.showsMinus ? skin.minusName : skin.noMinusName)
                .offset(x: skin.minusFrame.minX, y: skin.minusFrame.minY)
            digit(status.digits.minutesTens, x: 48)
            digit(status.digits.minutesOnes, x: 60)
            digit(status.digits.secondsTens, x: 78)
            digit(status.digits.secondsOnes, x: 90)
            // The 59x13 click area of #time.
            Color.clear
                .frame(width: 59, height: 13)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleTimeMode)
                .offset(x: 39, y: 26)
        }
    }

    @ViewBuilder private func digit(_ value: Int?, x: CGFloat) -> some View {
        if let value {
            SpriteImage(skin: skin, name: skin.digitSpriteName(value)).offset(x: x, y: 26)
        }
    }

    private var mediaInfo: some View {
        ZStack(alignment: .topLeading) {
            if let kbps = status.kbps { text(kbps, x: 111) }
            if let khz = status.khz { text(khz, x: 156) }
            SpriteImage(skin: skin, name: status.monoSelected ? "MAIN_MONO_SELECTED" : "MAIN_MONO")
                .offset(x: 212, y: 41)
            SpriteImage(skin: skin, name: status.stereoSelected ? "MAIN_STEREO_SELECTED" : "MAIN_STEREO")
                .offset(x: 239, y: 41)
        }
    }

    @ViewBuilder private func text(_ string: String, x: CGFloat) -> some View {
        if let image = skin.textImage(string) {
            Image(decorative: image, scale: 1).interpolation(.none).offset(x: x, y: 43)
        }
    }
}

/// Webamp's `.pause #time { animation: blink 2s step-start 1s infinite }`: visible for a second after
/// pausing, then hidden a second, visible a second... The task ends with the view, so nothing wakes up
/// once playback leaves the paused state.
private struct BlinkingView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var visible = true

    var body: some View {
        content
            .opacity(visible ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    visible.toggle()
                }
            }
    }
}
