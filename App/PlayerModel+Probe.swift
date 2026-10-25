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

    private enum CodingKeys: String, CodingKey {
        case output, feed, state, currentIndex, queue, notice, lastExternalOpen, tokenStore, maRequests
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
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension PlayerModel {
    /// The state probe's value. `lastExternalOpen` and `tokenStore` come from `RoadieConfiguration` (#0194) and
    /// `maRequests` from the scripted Music Assistant (#0197); until those land they read nil, "keychain" and [].
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
            lastExternalOpen: nil,
            tokenStore: "keychain",
            maRequests: [])
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
}
