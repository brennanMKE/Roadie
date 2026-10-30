import SkinBrowser
import SwiftUI

/// What `SkinBrowserStatusView` shows for a phase (#0217).
enum SkinBrowserStatusContent: Equatable {
    case needsFolder
    case failed(String)
    case progress

    static func content(for phase: SkinBrowserPhase) -> Self {
        switch phase {
        case .needsFolder: .needsFolder
        case .failed(let message): .failed(message)
        case .idle, .loading, .loaded: .progress
        }
    }
}

/// The window's non-grid states: no folder, loading, failed.
struct SkinBrowserStatusView: View {
    @Environment(PlayerModel.self) private var player
    let phase: SkinBrowserPhase

    var body: some View {
        switch SkinBrowserStatusContent.content(for: phase) {
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
        case .progress:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
