import Foundation

/// What a File Info panel shows for one track, with its rows already formatted. Shared by the main window's clutter
/// bar and the playlist.
public struct TrackInfo: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?
    /// "MP3", "FLAC"…: the file extension, uppercased.
    public var format: String?
    public var bitrateKbps: Int?
    public var sampleRate: Double?
    public var channels: Int?

    public init(
        title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil, format: String? = nil,
        bitrateKbps: Int? = nil, sampleRate: Double? = nil, channels: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.format = format
        self.bitrateKbps = bitrateKbps
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// The opened file's `format` wins over the track's metadata for sample rate and channels.
    public init(track: Track, format: PlaybackFormat?) {
        let fileFormat: String? = switch track.source {
        case .file(let url): url.pathExtension.isEmpty ? nil : url.pathExtension.uppercased()
        }
        self.init(
            title: track.title, artist: track.artist, album: track.album, duration: track.duration, format: fileFormat,
            bitrateKbps: track.bitrate, sampleRate: format?.sampleRate ?? track.sampleRate,
            channels: format?.channels ?? track.channels)
    }

    public var rows: [Row] {
        [
            Row("Title", Self.text(title)),
            Row("Artist", Self.text(artist)),
            Row("Album", Self.text(album)),
            Row("Duration", duration.map(Self.durationText) ?? Self.missing),
            Row("Format", Self.text(format)),
            Row("Bitrate", bitrateKbps.map { "\($0) kbps" } ?? Self.missing),
            Row("Sample rate", sampleRate.map(Self.rateText) ?? Self.missing),
            Row("Channels", channels.map(Self.channelsText) ?? Self.missing),
        ]
    }

    static let missing = "—"

    private static func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return missing }
        return value
    }

    /// m:ss, or h:mm:ss from an hour up.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "44.1 kHz", "48 kHz".
    static func rateText(_ hz: Double) -> String {
        var text = String(format: "%.1f", hz / 1000)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return "\(text) kHz"
    }

    static func channelsText(_ count: Int) -> String {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        default: "\(count) channels"
        }
    }
}
