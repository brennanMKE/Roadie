import LibraryBrowser
import SwiftUI

/// The transient bar under an open playlist's tracks (#0138): the edit in flight, or the refusal with Retry.
struct PlaylistEditBar: View {
    let editor: PlaylistEditor

    var body: some View {
        if let pending = editor.pending {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(pending.text)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("library.playlist.editBar")
        } else if let error = editor.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(error).lineLimit(2)
                Spacer()
                Button("Retry") { editor.retry() }
                Button("Dismiss") { editor.dismissError() }
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("library.playlist.editBar")
        }
    }
}
