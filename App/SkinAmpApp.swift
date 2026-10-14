import PlexKit
import SwiftUI
import TrackCache

@main
struct SkinAmpApp: App {
    @State private var model = PlayerModel()
    @State private var plexSettings = PlexSettingsModel(
        tokenStore: KeychainPlexTokenStore(),
        connectionTest: PlexConnectionTest(clientIdentifier: PlexClientIdentifier.stored()),
        account: PlexAccountClient(clientIdentifier: PlexClientIdentifier.stored()),
        openURL: { NSWorkspace.shared.open($0) })

    var body: some Scene {
        Window("SkinAmp", id: "main") {
            PlayerView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openFiles(replace: true) }
                    .keyboardShortcut("o")
                Button("Add to Playlist…") { model.openFiles(replace: false) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Open Skin…") { model.openSkin() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Window("Library", id: "library") {
            LibraryWindowView()
                .environment(model)
        }
        .keyboardShortcut("l")
        .defaultSize(width: 960, height: 600)

        Settings {
            SettingsView()
                .environment(plexSettings)
                .environment(model.cacheSettings)
        }
    }
}
