import Foundation

/// The format of the file the player has open, from the file itself rather than track metadata
/// (a library listing may carry no sample rate).
public struct PlaybackFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}
