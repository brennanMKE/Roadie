import SwiftUI

/// The Settings tabs; the selection persists so another window (the Welcome, #0169) can pick one before opening Settings.
enum SettingsTab: String {
    case library, musicAssistant, skins, visualization, updates
    static let defaultsKey = "settingsSelectedTab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.defaultsKey) private var tab: SettingsTab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "music.note.house") }
                .tag(SettingsTab.library)
            MusicAssistantSettingsView()
                .tabItem { Label("Music Assistant", systemImage: "hifispeaker.2") }
                .tag(SettingsTab.musicAssistant)
            SkinsSettingsView()
                .tabItem { Label("Skins", systemImage: "paintpalette") }
                .tag(SettingsTab.skins)
            VisualizationSettingsView()
                .tabItem { Label("Visualization", systemImage: "waveform") }
                .tag(SettingsTab.visualization)
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)
        }
        .frame(width: 480)
        .scenePadding()
    }
}
