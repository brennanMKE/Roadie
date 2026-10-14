import SkinBrowser
import SwiftUI

/// The window's non-grid states: no folder, loading, failed.
struct SkinBrowserStatusView: View {
    @Environment(PlayerModel.self) private var player
    let phase: SkinBrowserPhase

    var body: some View {
        switch phase {
        case .needsFolder:
            ContentUnavailableView {
                Label("No skins folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose a folder of .wsz files in Settings › Skins.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
                    .accessibilityIdentifier("skins.openSettings")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not read the skin index", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { player.skinBrowser.reload() }
                    .accessibilityIdentifier("skins.retry")
            }
        case .idle, .loading, .loaded:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
