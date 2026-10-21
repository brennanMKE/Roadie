import MusicAssistantKit
import SwiftUI

@main
struct SkinAmpApp: App {
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
                OpenLibraryWindowButton()
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

/// Window › Library (⌘L, #0115). SwiftUI's automatic Window-menu entry for the scene doesn't appear in this app, so the
/// item is explicit.
private struct OpenLibraryWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Library") { openWindow(id: "library") }
            .keyboardShortcut("l")
    }
}
