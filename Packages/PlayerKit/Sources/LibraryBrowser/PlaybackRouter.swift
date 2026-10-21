import Foundation
import MusicBackendKit
import Observation

/// What feeds This Mac (#0109): AudioCore's own queue (local files, the folder source), or Music Assistant's queue
/// for SkinAmp's own MA player, arriving over Sendspin.
public enum ThisMacFeed: Sendable, Equatable { case local, musicAssistant }

/// What changes the feed of This Mac (#0114).
public enum ThisMacFeedEvent: Sendable, Equatable {
    /// SkinAmp asked Music Assistant to play on This Mac.
    case musicAssistantPlayRequested
    /// That play failed. While a stream still runs (an earlier play), Music Assistant keeps the feed.
    case musicAssistantPlayFailed(isStreaming: Bool)
    /// A Sendspin stream started.
    case streamStarted
    /// The server ended the stream, or the Sendspin session dropped or was stopped.
    case streamStopped
    /// Local files, the folder source or a playlist double-click.
    case localPlayRequested
}

extension ThisMacFeed {
    /// The feed after `event`.
    public func after(_ event: ThisMacFeedEvent) -> ThisMacFeed {
        switch event {
        case .musicAssistantPlayRequested, .streamStarted: return .musicAssistant
        case .musicAssistantPlayFailed(let isStreaming): return isStreaming ? .musicAssistant : .local
        case .streamStopped, .localPlayRequested: return .local
        }
    }
}

@MainActor
@Observable
public final class ThisMacFeedState {
    public var feed: ThisMacFeed = .local
    public init() {}
}

/// Which backend owns an output. Commands and now-playing follow the selected output, not the Library's source:
/// This Mac is the local backend (AudioCore through `LocalPlayerOutput`) unless Music Assistant feeds it, and every
/// other id is a remote player (Music Assistant).
@MainActor
public final class PlaybackRouter {
    public let local: any MusicBackend
    public let remote: any MusicBackend
    public let feed: ThisMacFeedState

    public init(local: any MusicBackend, remote: any MusicBackend, feed: ThisMacFeedState = ThisMacFeedState()) {
        self.local = local
        self.remote = remote
        self.feed = feed
    }

    public func backend(for output: OutputDevice.ID) -> any MusicBackend {
        guard output == OutputDevice.thisMacID else { return remote }
        return feed.feed == .musicAssistant ? remote : local
    }

    /// As `backend(for:)`, except volume and balance on This Mac always act on the local `Player` (it reports
    /// volume to Music Assistant through Sendspin, #0108).
    public func backend(for output: OutputDevice.ID, command: TransportCommand) -> any MusicBackend {
        if output == OutputDevice.thisMacID {
            switch command {
            case .setVolume, .setBalance: return local
            default: break
            }
        }
        return backend(for: output)
    }
}

/// Whether local audio may start on the selected output (#0084). Local files play only on This Mac; while a
/// speaker is selected, opening, adding or dropping them is refused with a notice and the output is left alone.
public enum LocalPlaybackGate {
    public static let switchToThisMac = "Switch the output to This Mac to play local files."

    /// nil when local files may play on `output`, else the notice text.
    public static func refusal(forLocalFilesOn output: OutputDevice.ID) -> String? {
        output == OutputDevice.thisMacID ? nil : switchToThisMac
    }

    /// Local files play only through AudioCore, so never while This Mac is grouped with speakers (#0118).
    public static func refusal(forLocalFilesOn selection: OutputSelection) -> String? {
        selection == .thisMac ? nil : switchToThisMac
    }

    /// `playFromLibrary`'s rule: a source without `.remoteOutputs` can only play on This Mac.
    public static func refusal(source: BackendCapabilities, output: OutputDevice.ID) -> String? {
        output == OutputDevice.thisMacID || source.contains(.remoteOutputs) ? nil : switchToThisMac
    }
}
