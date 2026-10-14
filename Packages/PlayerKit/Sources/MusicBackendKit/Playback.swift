import Foundation

public struct OutputDevice: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable, Codable, RawRepresentable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public enum Kind: Hashable, Sendable { case thisMac, remote }

    public var id: ID
    public var name: String
    public var kind: Kind
    public var isAvailable: Bool

    public init(id: ID, name: String, kind: Kind, isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isAvailable = isAvailable
    }

    public static let thisMacID = ID(rawValue: "this-mac")
    public static let thisMac = OutputDevice(id: thisMacID, name: "This Mac", kind: .thisMac, isAvailable: true)
}

public enum TransportCommand: Hashable, Sendable {
    case play, pause, togglePlayPause, stop, next, previous
    case seek(TimeInterval)
    /// 0...1
    case setVolume(Float)
    /// -1...1
    case setBalance(Float)
    case setShuffle(Bool)
    /// The main window's two-state repeat: on repeats the whole queue.
    case setRepeat(Bool)
}

public enum PlayMode: Hashable, Sendable {
    /// Replace what is queued and start at `startIndex` of the expanded items.
    case replace(startIndex: Int = 0)
    /// Append; playback starts only if the output was idle with nothing queued.
    case append
}

public struct NowPlaying: Hashable, Sendable {
    public enum State: Hashable, Sendable { case stopped, loading, playing, paused }

    public var output: OutputDevice.ID
    public var state: State
    /// nil for a local file opened outside any backend.
    public var item: MediaID?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    /// Position at `updatedAt`; use `elapsed(at:)` while playing.
    public var elapsed: TimeInterval
    public var updatedAt: Date
    public var volume: Float?
    public var artwork: ArtworkRef?

    public init(
        output: OutputDevice.ID, state: State, item: MediaID? = nil, title: String? = nil, artist: String? = nil,
        album: String? = nil, duration: TimeInterval? = nil, elapsed: TimeInterval = 0, updatedAt: Date = Date(),
        volume: Float? = nil, artwork: ArtworkRef? = nil
    ) {
        self.output = output
        self.state = state
        self.item = item
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.updatedAt = updatedAt
        self.volume = volume
        self.artwork = artwork
    }

    public static func idle(on output: OutputDevice.ID, at date: Date = Date()) -> NowPlaying {
        NowPlaying(output: output, state: .stopped, updatedAt: date)
    }

    /// `elapsed` plus the time since `updatedAt` while playing, else `elapsed`; never past `duration`.
    public func elapsed(at now: Date) -> TimeInterval {
        var value = elapsed
        if state == .playing { value += max(0, now.timeIntervalSince(updatedAt)) }
        if let duration, duration > 0 { value = min(value, duration) }
        return max(0, value)
    }
}
