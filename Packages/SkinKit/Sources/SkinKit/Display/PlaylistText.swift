import Foundation

/// Webamp's playlist strings: TrackList.tsx row numbers, trackUtils `trackName`, utils `getTimeStr`,
/// RunningTimeDisplay.tsx.
public enum PlaylistText {
    /// 1-based, left-padded with U+00A0 to the digit count of `count`, then ". ".
    public static func rowNumber(_ index: Int, count: Int) -> String {
        let digits = String(max(count, 1)).count
        let number = String(index + 1)
        return String(repeating: "\u{00A0}", count: max(digits - number.count, 0)) + number + ". "
    }

    /// "artist - title", else the title, else the file name.
    public static func displayName(artist: String, title: String, fileName: String) -> String {
        if !artist.isEmpty && !title.isEmpty { return "\(artist) - \(title)" }
        if !title.isEmpty { return title }
        return fileName
    }

    /// "m:ss" (minutes unpadded, Webamp truncates the leading zero); nil or unknown (not finite, negative) = "".
    public static func time(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let whole = Int(seconds.rounded(.down))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// A queued row's place in the play-next list (#0179): "[n]" for 1-based `position`, "" when not queued.
    public static func queueMarker(_ position: Int?) -> String {
        guard let position, position > 0 else { return "" }
        return "[\(position)]"
    }

    /// "selected/total" padded with spaces to 18 text cells.
    public static func runningTime(selected: TimeInterval, total: TimeInterval) -> String {
        let text = "\(time(selected))/\(time(total))"
        return text + String(repeating: " ", count: max(18 - text.count, 0))
    }
}
