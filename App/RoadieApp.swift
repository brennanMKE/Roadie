import MusicAssistantKit
import SwiftUI

@main
struct RoadieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryWindowView()
                .environment(appDelegate.model)
                .environment(appDelegate.model.fallback)
                .environment(appDelegate.model.musicAssistantSettings)
                .environment(appDelegate.model.musicAssistantDiscovery)
        }
        .defaultSize(width: 960, height: 600)

        Window("Skins", id: "skins") {
            SkinBrowserWindowView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 920, height: 640)

        Settings {
            SettingsView()
                .environment(appDelegate.model.musicAssistantSettings)
                .environment(appDelegate.model.musicAssistantSelection)
                .environment(appDelegate.model.sendspinController)
                .environment(appDelegate.model.musicAssistantDiscovery)
                .environment(appDelegate.model.folderSettings)
                .environment(appDelegate.model.sources)
                .environment(appDelegate.model.fallback)
                .environment(appDelegate.model.skinLibrary)
                .environment(appDelegate.updater)
        }
        .commands {
            UpdateCommands(updater: appDelegate.updater)
            CommandGroup(replacing: .newItem) {
                Button("Open…") { appDelegate.model.openFiles(replace: true) }
                    .keyboardShortcut("o")
                Button("Add to Playlist…") { appDelegate.model.openFiles(replace: false) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Open Skin…") { appDelegate.model.openSkin() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Load Playlist…") { appDelegate.model.loadPlaylistFile() }
                Button("Save Playlist…") { appDelegate.model.savePlaylistFile() }
                    .keyboardShortcut("s")
            }
            CommandGroup(after: .help) {
                Button("Welcome to Roadie…") { appDelegate.welcome.show(openMuseum: false) }
            }
            SkinsCommands(model: appDelegate.model)
            PlaybackCommands(model: appDelegate.model)
            CommandGroup(after: .windowArrangement) {
                OpenLibraryWindowButton(showsShortcut: false)
                Divider()
                Button("Player") { appDelegate.player.show() }
                    .keyboardShortcut("1")
                Button("Windowshade") { appDelegate.model.toggleMainWindowShade() }
                    .keyboardShortcut("w", modifiers: [.command, .control])
                Button("Equalizer") { appDelegate.model.toggleEQWindow() }
                    .keyboardShortcut("2")
                Button("EQ Windowshade") { appDelegate.model.toggleEQWindowShade() }
                    .keyboardShortcut("e", modifiers: [.command, .control])
                Button("Playlist Windowshade") { appDelegate.model.togglePlaylistWindowShade() }
                    .keyboardShortcut("p", modifiers: [.command, .control])
                Button("Playlist Editor") { appDelegate.model.togglePlaylistWindow() }
                    .keyboardShortcut("3")
                Toggle(
                    "Always on Top",
                    isOn: Binding(
                        get: { appDelegate.model.isAlwaysOnTop }, set: { _ in appDelegate.model.toggleAlwaysOnTop() }))
                Toggle(
                    "Double Size",
                    isOn: Binding(
                        get: { appDelegate.model.isDoubleSize }, set: { _ in appDelegate.model.toggleDoubleSize() }))
            }
        }
    }
}

/// Opens (or brings forward) the Library window (#0115). It sits at the top of the Playback menu with ⌘L and in the
/// Window menu without it; SwiftUI's automatic Window-menu entry for the scene doesn't appear in this app.
struct OpenLibraryWindowButton: View {
    var showsShortcut = true
    /// When set (the Playback menu's ⌘L), the Library comes forward with its search field focused (#0185).
    var model: PlayerModel?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let button = Button("Library") {
            if let model { model.showLibrary() } else { openWindow(id: "library") }
        }
        if showsShortcut {
            button.keyboardShortcut("l")
        } else {
            button
        }
    }
}
