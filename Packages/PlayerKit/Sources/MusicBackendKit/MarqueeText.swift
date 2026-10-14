import Foundation

/// What the main window marquee shows (Webamp's getMarqueeText, getMediaText and trackUtils.trackName),
/// computed from the source-neutral `NowPlaying` snapshot.
public enum MarqueeText {
    /// Webamp: "Winamp 2.91".
    public static let idle = "SkinAmp"
    /// Shown while a backend track is still being fetched (docs/plan.md, TrackCache: a track starts after its download).
    public static let buffering = "Buffering\u{2026}"

    /// "Artist - Title", or the title when the artist is empty.
    public static func name(artist: String?, title: String) -> String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) - \(title)"
    }

    /// Webamp getTimeStr: "m:ss" with unpadded minutes ("3:45", "0:05", "62:05"). Truncates, never rounds up.
    public static func time(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }

    /// "1. Artist - Title (3:45)". The number prefix is omitted when `number` is nil; the parenthesis is
    /// omitted when the duration is unknown (<= 0), where Webamp would print `()`.
    public static func track(artist: String?, title: String, duration: TimeInterval?, number: Int?) -> String {
        var text = name(artist: artist, title: title)
        if let number { text = "\(number). \(text)" }
        if let duration, duration > 0 { text += " (\(time(duration)))" }
        return text
    }

    /// idle with no title; buffering while a backend track (one with an `item`) is loading; else the track text.
    /// Local files open in milliseconds and have no `item`, so they never say buffering.
    public static func display(_ nowPlaying: NowPlaying, number: Int?) -> String {
        guard let title = nowPlaying.title else { return idle }
        if nowPlaying.state == .loading, nowPlaying.item != nil { return buffering }
        return track(artist: nowPlaying.artist, title: title, duration: nowPlaying.duration, number: number)
    }

    // MARK: Slider focus text (Webamp marqueeUtils getVolumeText, getBalanceText, getSeekText)

    /// "Volume: 57%".
    public static func volume(_ volume: Float) -> String {
        "Volume: \(Int((min(max(volume, 0), 1) * 100).rounded()))%"
    }

    /// "Balance: Center", "Balance: 40% Left" or "Balance: 40% Right".
    public static func balance(_ balance: Float) -> String {
        let percent = Int((min(abs(balance), 1) * 100).rounded())
        if percent == 0 { return "Balance: Center" }
        return "Balance: \(percent)% \(balance < 0 ? "Left" : "Right")"
    }

    /// "Seek to: 1:23/3:45 (37%)" for a scrub `fraction` of `duration`.
    public static func seek(fraction: Double, duration: TimeInterval) -> String {
        let f = min(max(fraction, 0), 1)
        return "Seek to: \(time(f * duration))/\(time(duration)) (\(Int(f * 100))%)"
    }
}
