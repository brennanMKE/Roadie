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
    /// A group of speakers (a Music Assistant group player); the output picker lists these separately.
    public var isGroup: Bool
    /// The outputs this one can sync with (#0118); nil when unknown, which allows any.
    public var groupableWith: Set<ID>?

    public init(
        id: ID, name: String, kind: Kind, isAvailable: Bool = true, isGroup: Bool = false,
        groupableWith: Set<ID>? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isAvailable = isAvailable
        self.isGroup = isGroup
        self.groupableWith = groupableWith
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
    /// Append, then play these right after the current track, ahead of anything already queued to play next, in order
    /// (#0181; JTFE's `/ADD \\QUEUE`). Playback starts only if the output was idle with nothing queued.
    case next
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

    /// How far past a whole second each remote clock tick lands, so a tick never floors to the previous second.
    public static let clockLead: TimeInterval = 0.05

    /// When a 1 s clock for `selected` should start so that each tick lands just after the elapsed time
    /// crosses a whole second. nil on This Mac (the local player drives the view) and unless playing, so
    /// nothing ticks while idle, paused, loading or stopped.
    public func remoteClockAnchor(selected: OutputDevice.ID) -> Date? {
        remoteClockAnchor(followsLocalPlayer: selected == OutputDevice.thisMacID)
    }

    /// As above, keyed on whether the local queue drives the view: This Mac fed by Music Assistant (#0109) ticks
    /// from the snapshot like a speaker.
    public func remoteClockAnchor(followsLocalPlayer: Bool) -> Date? {
        guard !followsLocalPlayer, state == .playing else { return nil }
        return updatedAt.addingTimeInterval(-elapsed.truncatingRemainder(dividingBy: 1) + Self.clockLead)
    }
}
