import SkinBrowser
import SkinLibrary
import SwiftUI

struct SkinGridView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let browser = player.skinBrowser
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 12)], spacing: 12) {
                ForEach(browser.items) { record in
                    SkinCellView(record: record)
                        .onAppear { browser.loadMoreIfNeeded(current: record) }
                }
            }
            .padding()
            footer(browser)
        }
        .accessibilityIdentifier("skins.grid")
    }

    @ViewBuilder
    private func footer(_ browser: SkinBrowserModel) -> some View {
        switch GridFooterContent.content(loadMoreError: browser.loadMoreError, isLoadingMore: browser.isLoadingMore) {
        case .error(let message):
            HStack {
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { browser.retryLoadMore() }
            }
            .padding(.bottom)
        case .loading:
            ProgressView().padding(.bottom)
        case .nothing:
            EmptyView()
        }
    }
}

/// The load-more footer under the Skins and Museum grids (#0217): the error with Retry, a spinner, or nothing.
enum GridFooterContent: Equatable {
    case error(String)
    case loading
    case nothing

    static func content(loadMoreError: String?, isLoadingMore: Bool) -> Self {
        if let loadMoreError { return .error(loadMoreError) }
        return isLoadingMore ? .loading : .nothing
    }
}
