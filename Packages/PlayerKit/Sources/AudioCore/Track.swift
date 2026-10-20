import AVFoundation
import Foundation

public struct Track: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// A local file. A future stream source adds a case here; QueueStore drops kinds it does not know.
        case file(URL)
    }

    /// Per queue entry, so the same file can be queued twice.
    public let id: UUID
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval
    /// kbps
    public var bitrate: Int?
    /// Hz
    public var sampleRate: Double?
    public var channels: Int?
    public var source: Source

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval,
        bitrate: Int? = nil,
        sampleRate: Double? = nil,
        channels: Int? = nil,
        source: Source
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.source = source
    }
}

extension Track {
    /// Minimal local-file constructor: title is the file name, artist is empty, and
    /// duration / sample rate / channels come from `AVAudioFile`.
    public static func file(at url: URL) throws -> Track {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        let rate = format.sampleRate
        return Track(
            title: url.deletingPathExtension().lastPathComponent,
            artist: "",
            duration: rate > 0 ? Double(file.length) / rate : 0,
            sampleRate: rate,
            channels: Int(format.channelCount),
            source: .file(url)
        )
    }
}
