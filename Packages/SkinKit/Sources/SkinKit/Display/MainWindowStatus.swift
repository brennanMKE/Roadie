import Foundation

/// SkinKit does not import AudioCore, so the status carries its own transport enum.
public enum Transport: Sendable { case stopped, loading, playing, paused }

/// The pure view model the main window's time, media-info and indicator layer renders (Webamp
/// `.stop`/`.pause`/`.play` CSS rules). The SwiftUI layer is a thin mapping from this.
public struct MainWindowStatus: Equatable, Sendable {
    public var transport: Transport
    public var timeMode: TimeMode
    public var elapsed: TimeInterval
    public var duration: TimeInterval
    public var bitrateKbps: Int?
    public var sampleRate: Double?
    public var channels: Int?

    public init(
        transport: Transport, timeMode: TimeMode, elapsed: TimeInterval, duration: TimeInterval,
        bitrateKbps: Int?, sampleRate: Double?, channels: Int?
    ) {
        self.transport = transport
        self.timeMode = timeMode
        self.elapsed = elapsed
        self.duration = duration
        self.bitrateKbps = bitrateKbps
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// `.stop #time { display: none }`.
    public var showsTime: Bool { transport != .stopped }
    /// `.pause #time { animation: blink }`.
    public var blinksTime: Bool { transport == .paused }
    public var showsMinus: Bool { showsTime && timeMode == .remaining }
    public var digits: TimeDigits {
        showsTime ? .shown(mode: timeMode, elapsed: elapsed, duration: duration) : .blank
    }
    public var kbps: String? { showsTime ? MediaInfoText.kbps(bitrateKbps) : nil }
    public var khz: String? { showsTime ? MediaInfoText.khz(sampleRate: sampleRate) : nil }
    public var stereoSelected: Bool { showsTime && channels == 2 }
    public var monoSelected: Bool { showsTime && channels == 1 }
    /// nil while loading: Webamp hides #play-pause while working.
    public var indicator: String? {
        switch transport {
        case .playing: "MAIN_PLAYING_INDICATOR"
        case .paused: "MAIN_PAUSED_INDICATOR"
        case .stopped: "MAIN_STOPPED_INDICATOR"
        case .loading: nil
        }
    }
    public var workIndicator: String? {
        switch transport {
        case .loading: "MAIN_WORKING_INDICATOR"
        case .playing: "MAIN_NOT_WORKING_INDICATOR"
        case .paused, .stopped: nil
        }
    }
}
