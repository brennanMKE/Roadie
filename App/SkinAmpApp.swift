import MusicAssistantKit
import PlexKit
import SwiftUI
import TrackCache

@main
struct SkinAmpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var plexSettings = PlexSettingsModel(
        tokenStore: KeychainPlexTokenStore(),
        connectionTest: PlexConnectionTest(clientIdentifier: PlexClientIdentifier.stored()),
        account: PlexAccountClient(clientIdentifier: PlexClientIdentifier.stored()),
        openURL: { NSWorkspace.shared.open($0) })

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryWindowView()
                .environment(appDelegate.model)
                .environment(appDelegate.model.fallback)
        }
        .keyboardShortcut("l")
        .defaultSize(width: 960, height: 600)

        Window("Skins", id: "skins") {
            SkinBrowserWindowView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 920, height: 640)

        Settings {
            SettingsView()
                .environment(plexSettings)
                .environment(appDelegate.model.musicAssistantSettings)
                .environment(appDelegate.model.musicAssistantSelection)
                .environment(appDelegate.model.cacheSettings)
                .environment(appDelegate.model.folderSettings)
                .environment(appDelegate.model.sources)
                .environment(appDelegate.model.fallback)
                .environment(appDelegate.model.skinLibrary)
        }
        .commands {
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
            SkinsCommands(model: appDelegate.model)
            PlaybackCommands(model: appDelegate.model)
            CommandGroup(after: .windowArrangement) {
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
