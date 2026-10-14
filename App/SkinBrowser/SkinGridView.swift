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
        if let message = browser.loadMoreError {
            HStack {
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { browser.retryLoadMore() }
            }
            .padding(.bottom)
        } else if browser.isLoadingMore {
            ProgressView().padding(.bottom)
        }
    }
}
