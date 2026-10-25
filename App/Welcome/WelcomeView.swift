import Combine
import FolderBackendKit
import LibraryBrowser
import MusicAssistantKit
import SwiftUI

/// The Welcome window's checklist (#0169): skins, a music folder, and optionally Music Assistant. Every row shows live
/// status; nothing here starts network discovery or touches the Keychain.
struct WelcomeView: View {
    let openMuseumOnAppear: Bool
    let onContinue: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(SkinLibraryModel.self) private var skinLibrary
    @Environment(FolderSettingsModel.self) private var folderSettings
    @Environment(LibraryFallbackController.self) private var fallback
    @Environment(MusicAssistantSelectionController.self) private var selection
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var hasVerifiedServer = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                skinsSection
                musicSection
                musicAssistantSection
            }
            .formStyle(.grouped)
            Text("You can change all of this later in Settings. Help › Welcome to Roadie… brings this window back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack {
                Spacer()
                Button("Continue") { onContinue() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("welcome.continue")
            }
            .padding()
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { folderSettings.appeared() }
        .onDisappear { folderSettings.disappeared() }
        .onAppear {
            refreshServer()
            // Opened after the Welcome so the Skins window ends up in front.
            if openMuseumOnAppear { openMuseum() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in refreshServer() }
    }

    private var skinsSection: some View {
        Section {
            LabeledContent("Folder") {
                Text(skinLibrary.folderText).truncationMode(.middle).lineLimit(1).textSelection(.enabled)
            }
            Text(skinLibrary.countsText).foregroundStyle(.secondary)
            if let message = skinLibrary.errorMessage {
                Text(message).foregroundStyle(.red)
            }
            HStack {
                Button("Browse the Skin Museum…") { openMuseum() }
                    .accessibilityIdentifier("welcome.skins.museum")
                Button("Choose Folder…") { skinLibrary.chooseFolder() }
                    .accessibilityIdentifier("welcome.skins.choose")
                Button("Open Skin…") { player.openSkin() }
                    .accessibilityIdentifier("welcome.skins.open")
            }
        } header: {
            Text("Skins")
        } footer: {
            Text("Download skins from the Winamp Skin Museum into this folder, or open a .wsz you already have.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var musicSection: some View {
        Section {
            LabeledContent("Folder") {
                Text(folderSettings.pathText).truncationMode(.middle).lineLimit(1).textSelection(.enabled)
            }
            Text(folderSettings.statusText).foregroundStyle(folderSettings.isFailed ? .red : .secondary)
            HStack {
                Button("Choose Music Folder…") { chooseMusic() }
                    .accessibilityIdentifier("welcome.music.choose")
                Button("Open Library") { openWindow(id: "library") }
                    .disabled(!folderSettings.hasFolder)
                    .accessibilityIdentifier("welcome.music.openLibrary")
            }
        } header: {
            Text("Music Folder")
        }
    }

    private var musicAssistantSection: some View {
        Section {
            Text(serverText).foregroundStyle(.secondary)
            Button("Set Up Music Assistant…") {
                player.defaults.set(SettingsTab.musicAssistant.rawValue, forKey: SettingsTab.defaultsKey)
                openSettings()
            }
            .accessibilityIdentifier("welcome.ma.setup")
        } header: {
            Text("Music Assistant (optional)")
        }
    }

    private var serverText: String {
        guard hasVerifiedServer else { return "Not set up — Roadie works with a music folder alone." }
        return selection.statusText ?? "Connected to a Music Assistant server."
    }

    private func refreshServer() {
        hasVerifiedServer = MusicAssistantServerStore.hasVerifiedServer(defaults: player.defaults)
    }

    private func openMuseum() {
        player.pendingSkinsSource = .museum
        openWindow(id: "skins")
    }

    private func chooseMusic() {
        guard let url = chooseMusicFolder(startingAt: folderSettings.folderURL) else { return }
        folderSettings.choose(url)
        // With no verified server the folder is the only real source: browse it at once.
        if !MusicAssistantServerStore.hasVerifiedServer(defaults: player.defaults) { fallback.userSelected("folder") }
    }
}
