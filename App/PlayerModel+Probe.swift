import AudioCore
import Foundation
import LibraryBrowser
import MusicBackendKit
import SkinKit

/// What the hidden `state.probe` element reports (#0199): compound state a UI test can't read off the skinned controls.
struct TestProbe: Codable, Equatable {
    struct QueueItem: Codable, Equatable {
        var title: String
        var marker: String
        var current: Bool
    }

    var output: String
    var feed: String
    var state: String
    var currentIndex: Int?
    var queue: [QueueItem]
    var notice: String?
    var lastExternalOpen: String?
    var tokenStore: String
    var maRequests: [String]
    /// The applied skin's file name without `.wsz` (#0208), nil with no skin loaded.
    var skin: String? = nil
    /// The skins folder's `.wsz` files, folder-relative and sorted (#0208): the sandboxed test runner checks a trash
    /// or a download here rather than on disk. nil with no skins folder, and outside UI-test mode.
    var skinFiles: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case output, feed, state, currentIndex, queue, notice, lastExternalOpen, tokenStore, maRequests, skin, skinFiles
    }

    /// Writes `null` for the absent optionals, so every key is always in the JSON.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(output, forKey: .output)
        try c.encode(feed, forKey: .feed)
        try c.encode(state, forKey: .state)
        try c.encode(currentIndex, forKey: .currentIndex)
        try c.encode(queue, forKey: .queue)
        try c.encode(notice, forKey: .notice)
        try c.encode(lastExternalOpen, forKey: .lastExternalOpen)
        try c.encode(tokenStore, forKey: .tokenStore)
        try c.encode(maRequests, forKey: .maRequests)
        try c.encode(skin, forKey: .skin)
        try c.encode(skinFiles, forKey: .skinFiles)
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension PlayerModel {
    /// The state probe's value. `tokenStore` and `lastExternalOpen` come from the model's configuration (#0194), and
    /// `maRequests` only from the scripted server's redacted summaries (#0197), never its transports' raw `sent`
    /// (they hold the unredacted token).
    func testProbe() -> TestProbe {
        let tracks = playlist.tracks
        let current = playlist.currentIndex
        let queue = player.queue
        let showsMarkers = playlist.remote == nil && playlist.isLocal()
        return TestProbe(
            output: selectedOutput == OutputDevice.thisMacID ? "thisMac" : selectedOutput.rawValue,
            feed: thisMacFeed == .local ? "local" : "musicAssistant",
            state: "\(nowPlaying.state)",
            currentIndex: current,
            queue: tracks.enumerated().map { index, track in
                TestProbe.QueueItem(
                    title: PlaylistModel.displayName(track),
                    marker: showsMarkers ? PlaylistText.queueMarker(queue.upNextPosition(of: track.id)) : "",
                    current: index == current)
            },
            notice: notice?.text,
            lastExternalOpen: lastExternalOpen?.absoluteString,
            tokenStore: tokenStoreKind,
            maRequests: scriptedRequestSummaries,
            skin: self.skin == nil ? nil : skinName,
            skinFiles: configuration.isUITest ? skinLibrary.folderURL.map { Self.wszFiles(in: $0) } : nil)
    }

    /// `.wsz` files under `folder`, as sorted folder-relative paths.
    private static func wszFiles(in folder: URL) -> [String] {
        let root = folder.standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(atPath: root) else { return [] }
        return walk.compactMap { $0 as? String }.filter { $0.lowercased().hasSuffix(".wsz") }.sorted()
    }

    private var scriptedRequestSummaries: [String] {
        #if DEBUG
        scriptedMusicAssistant?.recentCommandSummaries() ?? []
        #else
        []
        #endif
    }

    /// The position slider's value: `mm:ss / mm:ss`.
    func positionAccessibilityValue(at now: Date) -> String {
        let status = mainWindowStatus(at: now)
        return "\(Self.clock(status.elapsed)) / \(Self.clock(status.duration))"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

extension MainWindowStatus {
    /// The main window's displays as accessibility values (#0199).
    var accessibility: (state: String, time: String, kbps: String, khz: String, stereo: String) {
        let state: String =
            switch transport {
            case .playing: "playing"
            case .paused: "paused"
            case .stopped: "stopped"
            case .loading: "loading"
            }
        let d = digits
        let time: String
        if let mt = d.minutesTens, let mo = d.minutesOnes, let st = d.secondsTens, let so = d.secondsOnes {
            time = "\(timeMode.rawValue) \(showsMinus ? "-" : "")\(mt)\(mo):\(st)\(so)"
        } else {
            time = "\(timeMode.rawValue) --:--"
        }
        let stereo = stereoSelected ? "stereo" : monoSelected ? "mono" : "none"
        return (
            state, time, (kbps ?? "").trimmingCharacters(in: .whitespaces), (khz ?? "").trimmingCharacters(in: .whitespaces),
            stereo
        )
    }
}

extension VisualizerModel.Mode {
    var accessibilityValue: String {
        switch self {
        case .spectrum: "spectrum"
        case .oscilloscope: "oscilloscope"
        case .off: "off"
        }
    }
}

extension PlaylistModel.Row {
    /// `marker=[2] duration=3:21 current=false`.
    var accessibilityValue: String { "marker=\(marker) duration=\(duration) current=\(isCurrent)" }
}

extension PlaylistLayout.Menu {
    var accessibilityID: String {
        switch self {
        case .add: AXID.PL.Menu.add
        case .remove: AXID.PL.Menu.rem
        case .selection: AXID.PL.Menu.sel
        case .misc: AXID.PL.Menu.misc
        case .list: AXID.PL.Menu.list
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .add: "Add"
        case .remove: "Remove"
        case .selection: "Select"
        case .misc: "Misc"
        case .list: "List"
        }
    }

    /// The button's name as Winamp skins draw it.
    var buttonName: String {
        switch self {
        case .add: "ADD"
        case .remove: "REM"
        case .selection: "SEL"
        case .misc: "MISC"
        case .list: "LIST"
        }
    }

    /// "LIST: Load List, Save List, New List": the button, then its entries nearest first (bottom up), with the
    /// labels VoiceOver reads for them. REMOVE MISC does nothing (`PlaylistMenu.command(forSprite:)` is nil and it
    /// pops up nothing), so it's left out (#0227).
    var tooltip: String {
        let labels = PlaylistLayout.entrySprites(self).reversed()
            .filter { $0 != "PLAYLIST_REMOVE_MISC" }
            .map { AXID.PL.Menu.entries[$0]?.label ?? $0 }
        return "\(buttonName): " + labels.joined(separator: ", ")
    }
}
