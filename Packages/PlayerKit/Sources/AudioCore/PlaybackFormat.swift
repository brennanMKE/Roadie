import Foundation

/// The format of the file the player has open, from the file itself rather than track metadata
/// (Plex listings carry no sample rate).
public struct PlaybackFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}
