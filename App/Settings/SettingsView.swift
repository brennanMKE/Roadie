import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PlexSettingsView()
                .tabItem { Label("Plex", systemImage: "server.rack") }
            // #0013 adds Cache; a Skins tab comes with M6.
        }
        .frame(width: 480)
        .scenePadding()
    }
}
