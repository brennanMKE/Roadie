import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "music.note.house") }
            MusicAssistantSettingsView()
                .tabItem { Label("Music Assistant", systemImage: "hifispeaker.2") }
            PlexSettingsView()
                .tabItem { Label("Plex", systemImage: "server.rack") }
            CacheSettingsView()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
            SkinsSettingsView()
                .tabItem { Label("Skins", systemImage: "paintpalette") }
        }
        .frame(width: 480)
        .scenePadding()
    }
}
