import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "music.note.house") }
            PlexSettingsView()
                .tabItem { Label("Plex", systemImage: "server.rack") }
            CacheSettingsView()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
            // A Skins tab comes with M6.
        }
        .frame(width: 480)
        .scenePadding()
    }
}
