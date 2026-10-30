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
                SpriteImage(skin: skin, name: indicator)
                    .offset(x: MainWindowLayout.playIndicator.x, y: MainWindowLayout.playIndicator.y)
            }
            if let work = status.workIndicator {
                // The sprite is listed 9 wide but Webamp draws 3 px.
                SpriteImage(skin: skin, name: work)
                    .frame(
                        width: MainWindowLayout.workIndicator.width, height: MainWindowLayout.workIndicator.height,
                        alignment: .topLeading)
                    .clipped()
                    .offset(x: MainWindowLayout.workIndicator.minX, y: MainWindowLayout.workIndicator.minY)
            }
            if status.showsTime {
                if status.blinksTime {
                    BlinkingView { time }
                } else {
                    time
                }
                // Outside the blinking digits: at opacity 0 a view isn't hit-testable, so while paused a click on the
                // time missed every other second (#0202).
                timeHitArea
            }
            mediaInfo
            accessibilityMarkers
        }
    }

    /// The displays as accessibility elements, there whether or not their sprites draw (#0199).
    @ViewBuilder private var accessibilityMarkers: some View {
        let ax = status.accessibility
        AXMarker(id: AXID.Main.state, label: "Play state", value: ax.state, frame: CGRect(
            origin: MainWindowLayout.playIndicator, size: CGSize(width: 9, height: 9)))
        AXMarker(id: AXID.Main.time, label: "Time", value: ax.time, frame: MainWindowLayout.timeHitArea)
        AXMarker(id: AXID.Main.kbps, label: "kbps", value: ax.kbps, frame: CGRect(
            origin: MainWindowLayout.kbps, size: CGSize(width: 15, height: 6)))
        AXMarker(id: AXID.Main.khz, label: "kHz", value: ax.khz, frame: CGRect(
            origin: MainWindowLayout.khz, size: CGSize(width: 10, height: 6)))
        AXMarker(id: AXID.Main.stereo, label: "Channels", value: ax.stereo, frame: CGRect(
            x: MainWindowLayout.mono.x, y: MainWindowLayout.mono.y,
            width: max(MainWindowLayout.stereo.x + 29 - MainWindowLayout.mono.x, 1), height: 12))
    }

    private var time: some View {
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: status.showsMinus ? skin.minusName : skin.noMinusName)
                .offset(x: skin.minusFrame.minX, y: skin.minusFrame.minY)
            digit(status.digits.minutesTens, x: MainWindowLayout.digitXs[0])
            digit(status.digits.minutesOnes, x: MainWindowLayout.digitXs[1])
            digit(status.digits.secondsTens, x: MainWindowLayout.digitXs[2])
            digit(status.digits.secondsOnes, x: MainWindowLayout.digitXs[3])
        }
    }

    /// The 59x13 click area of #time.
    private var timeHitArea: some View {
        Color.clear
            .frame(width: MainWindowLayout.timeHitArea.width, height: MainWindowLayout.timeHitArea.height)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleTimeMode)
            .offset(x: MainWindowLayout.timeHitArea.minX, y: MainWindowLayout.timeHitArea.minY)
    }

    @ViewBuilder private func digit(_ value: Int?, x: CGFloat) -> some View {
        if let value {
            SpriteImage(skin: skin, name: skin.digitSpriteName(value)).offset(x: x, y: MainWindowLayout.digitY)
        }
    }

    private var mediaInfo: some View {
        ZStack(alignment: .topLeading) {
            if let kbps = status.kbps { text(kbps, at: MainWindowLayout.kbps) }
            if let khz = status.khz { text(khz, at: MainWindowLayout.khz) }
            SpriteImage(skin: skin, name: status.monoSelected ? "MAIN_MONO_SELECTED" : "MAIN_MONO")
                .offset(x: MainWindowLayout.mono.x, y: MainWindowLayout.mono.y)
            SpriteImage(skin: skin, name: status.stereoSelected ? "MAIN_STEREO_SELECTED" : "MAIN_STEREO")
                .offset(x: MainWindowLayout.stereo.x, y: MainWindowLayout.stereo.y)
        }
    }

    @ViewBuilder private func text(_ string: String, at point: CGPoint) -> some View {
        if let image = skin.textImage(string) {
            Image(decorative: image, scale: 1).interpolation(.none).offset(x: point.x, y: point.y)
        }
    }
}

/// Webamp's `.pause #time { animation: blink 2s step-start 1s infinite }`: visible for a second after
/// pausing, then hidden a second, visible a second... The task ends with the view, so nothing wakes up
/// once playback leaves the paused state.
struct BlinkingView<Content: View>: View {
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
