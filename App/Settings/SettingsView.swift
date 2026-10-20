import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "music.note.house") }
            MusicAssistantSettingsView()
                .tabItem { Label("Music Assistant", systemImage: "hifispeaker.2") }
            SkinsSettingsView()
                .tabItem { Label("Skins", systemImage: "paintpalette") }
        }
        .frame(width: 480)
        .scenePadding()
    }
}
