import SwiftUI
import TrackCache

struct CacheSettingsView: View {
    @Environment(CacheSettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Storage") {
                LabeledContent("Used", value: model.usageText)
                    .accessibilityIdentifier("cache.usage")
                Text("\(model.fileCount) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Limit", selection: $model.limitBytes) {
                    // A saved value outside the list (an older build, a hand edit) still shows.
                    if !CacheSettingsModel.limitChoices.contains(model.limitBytes) {
                        Text(model.limitText).tag(model.limitBytes)
                    }
                    ForEach(CacheSettingsModel.limitChoices, id: \.self) { bytes in
                        Text(CacheSettingsModel.format(bytes)).tag(bytes)
                    }
                }
                .accessibilityIdentifier("cache.limit")
            }

            Section {
                HStack {
                    Button("Clear Cache") { Task { await model.clearCache() } }
                        .disabled(!model.canClear)
                        .accessibilityIdentifier("cache.clear")
                    if model.isClearing {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            } header: {
                Text("Clear")
            } footer: {
                Text("Downloaded Plex tracks are kept here so they play again without the network. The oldest are removed when the limit is reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
