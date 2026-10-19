import AppKit
import SkinKit

/// The main window's options menu: its state, and one exhaustive switch from a command onto the model.
extension PlayerModel {
    var mainMenuState: MainMenuState {
        MainMenuState(
            timeMode: timeMode, isEQWindowOpen: isEQWindowOpen, isPlaylistWindowOpen: isPlaylistWindowOpen,
            isMainShaded: isMainWindowShaded, isEQShaded: isEQWindowShaded, isPlaylistShaded: isPlaylistWindowShaded,
            isRepeating: isRepeating, isShuffled: isShuffled, canNavigateSkins: skinBrowser.canNavigate,
            isAlwaysOnTop: isAlwaysOnTop, isDoubleSize: isDoubleSize)
    }

    func perform(_ command: MainMenuCommand) {
        switch command {
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        case .openFiles: openFiles(replace: true)
        case .addFiles: openFiles(replace: false)
        case .toggleEQWindow: toggleEQWindow()
        case .togglePlaylistWindow: togglePlaylistWindow()
        case .openSkin: openSkin()
        case .nextSkin: skinBrowser.next()
        case .previousSkin: skinBrowser.previous()
        case .randomSkin: skinBrowser.random()
        case .timeElapsed: setTimeMode(.elapsed)
        case .timeRemaining: setTimeMode(.remaining)
        case .toggleAlwaysOnTop: toggleAlwaysOnTop()
        case .toggleDoubleSize: toggleDoubleSize()
        case .toggleMainShade: toggleMainWindowShade()
        case .toggleEQShade: toggleEQWindowShade()
        case .togglePlaylistShade: togglePlaylistWindowShade()
        case .toggleRepeat: toggleRepeat()
        case .toggleShuffle: toggleShuffle()
        case .previous: previous()
        case .play: play()
        case .pause: pause()
        case .stop: stop()
        case .next: next()
        case .quit: NSApp.terminate(nil)
        }
    }
}
