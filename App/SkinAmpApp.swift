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
        }
        .keyboardShortcut("l")
        .defaultSize(width: 960, height: 600)

        Settings {
            SettingsView()
                .environment(plexSettings)
                .environment(appDelegate.model.cacheSettings)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { appDelegate.model.openFiles(replace: true) }
                    .keyboardShortcut("o")
                Button("Add to Playlist…") { appDelegate.model.openFiles(replace: false) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Open Skin…") { appDelegate.model.openSkin() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Player") { appDelegate.player.show() }
                    .keyboardShortcut("1")
            }
        }
    }
}
