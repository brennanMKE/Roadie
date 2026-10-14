import LibraryBrowser
import SwiftUI

/// What a column shows while the source is not connected: progress, or the failure with its fix.
struct LibraryStatusView: View {
    let library: LibraryBrowserModel

    var body: some View {
        switch library.connection {
        case .idle, .connecting:
            ProgressView("Connecting to \(library.backend.displayName)\u{2026}")
                .accessibilityIdentifier("library.status")
        case .failed(let message, let needsSettings):
            ContentUnavailableView {
                Label("Can't open the library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if needsSettings {
                    SettingsLink { Text("Open Settings\u{2026}") }
                        .accessibilityIdentifier("library.openSettings")
                } else {
                    Button("Retry") { library.retryConnection() }
                        .accessibilityIdentifier("library.retry")
                }
            }
            .accessibilityIdentifier("library.status")
        case .connected:
            EmptyView()
        }
    }
}
