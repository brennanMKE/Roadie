import LibraryBrowser
import SwiftUI

/// The transient bar under an open playlist's tracks (#0138): the edit in flight, or the refusal with Retry.
struct PlaylistEditBar: View {
    let editor: PlaylistEditor

    /// What the bar shows: the edit in flight wins over an older refusal (#0215).
    enum Content: Equatable {
        case pending(String)
        case error(String)
        case nothing
    }

    static func content(pending: String?, error: String?) -> Content {
        if let pending { return .pending(pending) }
        if let error { return .error(error) }
        return .nothing
    }

    var body: some View {
        switch Self.content(pending: editor.pending?.text, error: editor.error) {
        case .pending(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("library.playlist.editBar")
        case .error(let error):
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
        case .nothing:
            EmptyView()
        }
    }
}
