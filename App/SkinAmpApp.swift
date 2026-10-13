import PlexKit
import SwiftUI

@main
struct SkinAmpApp: App {
    @State private var model = PlayerModel()
    @State private var plexSettings = PlexSettingsModel(
        tokenStore: KeychainPlexTokenStore(),
        connectionTest: PlexConnectionTest(clientIdentifier: PlexClientIdentifier.stored()))

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

        Settings {
            SettingsView()
                .environment(plexSettings)
        }
    }
}
