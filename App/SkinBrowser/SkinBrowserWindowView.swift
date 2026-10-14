import SkinBrowser
import SkinLibrary
import SwiftUI

/// The Skins window: a grid of thumbnails over the SQLite index, with search, a status filter and a random button.
struct SkinBrowserWindowView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var browser = player.skinBrowser
        VStack(spacing: 0) {
            content(browser)
            Divider()
            statusBar(browser)
        }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search skins by name or readme")
        .onSubmit(of: .search) { browser.searchNow() }
        .toolbar {
            ToolbarItem {
                Picker("Status", selection: $browser.filter) {
                    ForEach(SkinStatusFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("skins.filter")
            }
            ToolbarItem {
                Button("Random", systemImage: "dice") { browser.random() }
                    .disabled(!browser.canNavigate)
                    .accessibilityIdentifier("skins.random")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { browser.indexDidChange() }
                    .accessibilityIdentifier("skins.refresh")
            }
        }
        .task { browser.appeared() }
        .onDisappear { browser.disappeared() }
        .navigationTitle("Skins")
        .frame(minWidth: 640, minHeight: 400)
    }

    @ViewBuilder
    private func content(_ browser: SkinBrowserModel) -> some View {
        switch browser.phase {
        case .needsFolder, .loading, .idle, .failed:
            SkinBrowserStatusView(phase: browser.phase)
        case .loaded:
            if browser.items.isEmpty {
                if browser.query.hasText {
                    ContentUnavailableView.search(text: browser.query.text)
                } else {
                    ContentUnavailableView("No skins match", systemImage: "square.grid.2x2")
                }
            } else {
                SkinGridView()
            }
        }
    }

    private func statusBar(_ browser: SkinBrowserModel) -> some View {
        HStack(spacing: 8) {
            Text(SkinBrowserFormat.countLabel(matching: browser.matchCount, total: browser.counts?.skins, isFiltered: browser.isFiltered))
            if let elapsed = SkinBrowserFormat.elapsedLabel(browser.lastQueryDuration) {
                Text(elapsed).foregroundStyle(.secondary)
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
        .accessibilityIdentifier("skins.status")
    }
}
