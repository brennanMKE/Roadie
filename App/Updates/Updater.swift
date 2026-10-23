import Foundation
import Observation
import Sparkle
import SwiftUI

/// Sparkle's updater for the app (#0158, docs/sparkle.md). It starts only when the build carries both `SUFeedURL` and
/// `SUPublicEDKey`; Debug builds leave them empty, so they (and the VM's launch smoke test) never touch the network or
/// show Sparkle's first-launch prompt. The updater's state is mirrored through KVO so SwiftUI can observe it.
@MainActor
@Observable
final class Updater {
    /// Both Info.plist keys are non-empty, so the updater was started.
    let isConfigured: Bool
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var lastUpdateCheckDate: Date?

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !feed.isEmpty && !key.isEmpty
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured, updaterDelegate: nil, userDriverDelegate: nil)
        guard isConfigured else { return }
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in self?.scheduleRefresh() },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in self?.scheduleRefresh() },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in self?.scheduleRefresh() },
            updater.observe(\.lastUpdateCheckDate) { [weak self] _, _ in self?.scheduleRefresh() },
        ]
        refresh()
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ on: Bool) {
        guard isConfigured else { return }
        controller.updater.automaticallyChecksForUpdates = on
        refresh()
    }

    func setAutomaticallyDownloadsUpdates(_ on: Bool) {
        guard isConfigured else { return }
        controller.updater.automaticallyDownloadsUpdates = on
        refresh()
    }

    /// KVO can fire off the main actor; read the values back on it.
    nonisolated private func scheduleRefresh() {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func refresh() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }
}

/// Roadie › Check for Updates…, right after About Roadie.
struct UpdateCommands: Commands {
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
