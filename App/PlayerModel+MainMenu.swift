import AppKit
import SkinKit

/// The main window's options menu: its state, and one exhaustive switch from a command onto the model.
extension PlayerModel {
    var mainMenuState: MainMenuState {
        MainMenuState(
            timeMode: timeMode, isEQWindowOpen: isEQWindowOpen, isPlaylistWindowOpen: isPlaylistWindowOpen,
            isLibraryWindowOpen: libraryWindow?.isVisible ?? false,
            isMainShaded: isMainWindowShaded, isEQShaded: isEQWindowShaded, isPlaylistShaded: isPlaylistWindowShaded,
            isRepeating: isRepeating, isShuffled: isShuffled, canNavigateSkins: skinBrowser.canNavigate,
            isAlwaysOnTop: isAlwaysOnTop, isDoubleSize: isDoubleSize,
            canCheckForUpdates: updateActions?.canCheck() ?? false)
    }

    func perform(_ command: MainMenuCommand) {
        switch command {
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        case .checkForUpdates: updateActions?.check()
        case .openFiles: openFiles(replace: true)
        case .addFiles: openFiles(replace: false)
        case .toggleEQWindow: toggleEQWindow()
        case .togglePlaylistWindow: togglePlaylistWindow()
        case .toggleLibraryWindow: showLibrary()
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

// MARK: - Library (#0185)

extension PlayerModel {
    /// The Library window (a SwiftUI `Window` scene, id "library"), when it exists.
    var libraryWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("library") == true }
    }

    /// Opens or brings forward the Library and puts the cursor in its search field (#0185).
    func showLibrary(focusSearch: Bool = true) {
        if let window = libraryWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "library")
        }
        NSApp.activate()
        if focusSearch { focusLibrarySearch(attempts: 10) }
    }

    /// The window and its toolbar may not exist yet right after `openWindow`, so this retries every 50 ms.
    private func focusLibrarySearch(attempts: Int) {
        Task { @MainActor [weak self] in
            for _ in 0..<attempts {
                if let window = self?.libraryWindow, window.isVisible, Self.focusSearch(in: window) { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func focusSearch(in window: NSWindow) -> Bool {
        let items = window.toolbar?.items ?? []
        if let item = items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
            return true
        }
        let roots = items.compactMap(\.view) + [window.contentView].compactMap { $0 }
        for root in roots {
            if let field = searchField(in: root) {
                return window.makeFirstResponder(field)
            }
        }
        return false
    }

    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}
