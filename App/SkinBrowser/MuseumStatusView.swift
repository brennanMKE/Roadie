import SkinBrowser
import SwiftUI

/// The Museum tab: the source picker, search, the grid or its offline/failed/empty states, and a status bar (#0126).
/// Shown only when the user picks Museum, so `appeared()` here is the first network use.
struct MuseumModeView: View {
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayerModel.museumShowsNSFWKey) private var showsNSFW = false
    let sourcePicker: AnyView

    var body: some View {
        @Bindable var museum = player.museumBrowser
        VStack(spacing: 0) {
            MuseumStatusView()
            Divider()
            statusBar(museum)
        }
        .searchable(text: $museum.searchText, placement: .toolbar, prompt: "Search the Winamp Skin Museum")
        .onSubmit(of: .search) { museum.searchNow() }
        .toolbar {
            ToolbarItem(placement: .navigation) { sourcePicker }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { museum.retry() }
                    .accessibilityIdentifier("skins.museum.refresh")
            }
        }
        .task {
            if museum.showsNSFW != showsNSFW { museum.showsNSFW = showsNSFW }
            museum.appeared()
        }
        .onChange(of: showsNSFW) { _, value in museum.showsNSFW = value }
        .onDisappear { museum.disappeared() }
        .navigationTitle("Skins")
        .frame(minWidth: 640, minHeight: 400)
    }

    private func statusBar(_ museum: MuseumBrowserModel) -> some View {
        HStack(spacing: 8) {
            if let total = museum.total {
                Text("Skins from skins.webamp.org · \(total.formatted()) skins")
            } else {
                Text("Skins from skins.webamp.org")
            }
            if museum.usingCachedResults {
                Text("Offline, showing cached results").foregroundStyle(.secondary)
            }
            Spacer()
            if player.skinLibrary.isIndexing {
                ProgressView().controlSize(.small)
                Text(player.skinLibrary.progressText ?? "Indexing…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("skins.museum.status")
    }
}

/// What `MuseumStatusView` shows (#0217): the folder prompt above the content when no skins folder is set.
enum MuseumStatusContent: Equatable {
    case loading
    case offline(String)
    case failed(String)
    case noSkins
    case noResults(String)
    case grid

    static func content(for phase: MuseumBrowserPhase, isEmpty: Bool, searchText: String) -> Self {
        switch phase {
        case .idle, .loading: return .loading
        case .offline(let message): return .offline(message)
        case .failed(let message): return .failed(message)
        case .loaded:
            guard isEmpty else { return .grid }
            let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .noSkins : .noResults(text)
        }
    }

    static func showsFolderPrompt(hasFolder: Bool) -> Bool { !hasFolder }
}

/// The Museum content area: the grid, or the loading/offline/failed/empty states with Retry.
struct MuseumStatusView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let museum = player.museumBrowser
        VStack(spacing: 0) {
            if MuseumStatusContent.showsFolderPrompt(hasFolder: player.skinLibrary.hasFolder) {
                folderPrompt
                Divider()
            }
            content(museum)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ museum: MuseumBrowserModel) -> some View {
        switch MuseumStatusContent.content(for: museum.phase, isEmpty: museum.items.isEmpty, searchText: museum.searchText) {
        case .loading:
            ProgressView("Loading the Skin Museum…")
        case .offline(let message):
            ContentUnavailableView {
                Label("The Skin Museum can't be reached", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { museum.retry() }.accessibilityIdentifier("skins.museum.retry")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("The Skin Museum failed to load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { museum.retry() }.accessibilityIdentifier("skins.museum.retry")
            }
        case .noSkins:
            ContentUnavailableView("No skins", systemImage: "square.grid.2x2")
        case .noResults(let text):
            ContentUnavailableView.search(text: text)
        case .grid:
            MuseumGridView()
        }
    }

    private var folderPrompt: some View {
        HStack {
            Image(systemName: "folder.badge.questionmark")
            Text("Choose a skins folder to download skins. Downloads go to its Museum folder.")
            Spacer()
            Button("Choose Skins Folder…") { player.skinLibrary.chooseFolder() }
                .accessibilityIdentifier("skins.museum.chooseFolder")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
