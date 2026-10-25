import SkinBrowser
import SkinLibrary
import SwiftUI

/// Which grid the Skins window shows (#0126).
enum SkinsSource: String, CaseIterable, Identifiable {
    case library, museum
    var id: String { rawValue }
    var title: String { self == .library ? "Library" : "Museum" }
}

/// The Skins window: the local Library (a grid over the SQLite index, with search, a status filter and a random
/// button) or the Winamp Skin Museum. The Museum makes no request until its tab is shown.
struct SkinBrowserWindowView: View {
    @Environment(PlayerModel.self) private var player
    @SceneStorage("skins.source") private var source: SkinsSource = .library

    var body: some View {
        @Bindable var browser = player.skinBrowser
        Group {
            switch source {
            case .library: libraryBody
            case .museum: MuseumModeView(sourcePicker: AnyView(sourcePicker))
            }
        }
        .task {
            // #0169: a caller (the Welcome window, the placeholder's Browse button) asked for a tab.
            if let pending = player.pendingSkinsSource {
                source = pending
                player.pendingSkinsSource = nil
            }
        }
        .onChange(of: player.pendingSkinsSource) { _, pending in
            guard let pending else { return }
            source = pending
            player.pendingSkinsSource = nil
        }
        .alert(
            "Move to Trash", isPresented: Binding(get: { browser.trashError != nil }, set: { if !$0 { browser.trashError = nil } })
        ) {
            Button("OK", role: .cancel) { browser.trashError = nil }
        } message: {
            Text(browser.trashError ?? "")
        }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $source) {
            ForEach(SkinsSource.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier(AXID.Skins.source)
    }

    private var libraryBody: some View {
        @Bindable var browser = player.skinBrowser
        return VStack(spacing: 0) {
            content(browser)
            Divider()
            statusBar(browser)
        }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search skins by name or readme")
        .onSubmit(of: .search) { browser.searchNow() }
        .toolbar {
            ToolbarItem(placement: .navigation) { sourcePicker }
            ToolbarItem {
                Picker("Status", selection: $browser.filter) {
                    ForEach(SkinStatusFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(AXID.Skins.filter)
            }
            ToolbarItem {
                Button("Random", systemImage: "dice") { browser.random() }
                    .disabled(!browser.canNavigate)
                    .accessibilityIdentifier(AXID.Skins.random)
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { browser.indexDidChange() }
                    .accessibilityIdentifier(AXID.Skins.refresh)
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
