import SwiftUI

/// Settings › Updates (#0158): Sparkle's automatic checks and downloads, Check Now and the last check.
struct UpdatesSettingsView: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) })
                )
                .accessibilityIdentifier("updates.autoCheck")
                Toggle(
                    "Automatically download and install updates",
                    isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates },
                        set: { updater.setAutomaticallyDownloadsUpdates($0) })
                )
                .disabled(!updater.automaticallyChecksForUpdates)
                .accessibilityIdentifier("updates.autoDownload")
            }
            .disabled(!updater.isConfigured)

            Section {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                    .accessibilityIdentifier("updates.checkNow")
                LabeledContent(
                    "Last checked",
                    value: updater.lastUpdateCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                #if DEBUG
                    Text("Updates are off in development builds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                #endif
            }
        }
    }
}
