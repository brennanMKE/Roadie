import Foundation

/// Webamp's `massageKbps`/`massageKhz` plus the `getKbps`/`getKhz` padding, in this project's units
/// (`Track.bitrate` is kbps, `sampleRate` is Hz).
public enum MediaInfoText {
    /// 3 characters: "  0" for nil, " 96", "128", "14H" (>= 1000, first two digits), " 1C" (>= 10000, first digit).
    public static func kbps(_ kbps: Int?) -> String {
        guard let kbps else { return "  0" }
        let digits = String(max(kbps, 0))
        if kbps >= 10000 { return pad(String(digits.prefix(1)) + "C", to: 3) }
        if kbps >= 1000 { return String(digits.prefix(2)) + "H" }
        return pad(digits, to: 3)
    }

    /// 2 characters: " 0" for nil, " 8", "44", "48". Webamp's quirks are kept: 10 kHz or less shows only the
    /// first digit (so 10 reads " 1"), and 100 kHz or more shows characters 1...2 ("92" for 192000).
    public static func khz(sampleRate hz: Double?) -> String {
        guard let hz, hz.isFinite else { return " 0" }
        let value = max(Int((hz / 1000).rounded()), 0)
        let digits = String(value)
        if value >= 100 { return String(digits.dropFirst().prefix(2)) }
        if value <= 10 { return pad(String(digits.prefix(1)), to: 2) }
        return pad(digits, to: 2)
    }

    private static func pad(_ text: String, to width: Int) -> String {
        String(repeating: " ", count: max(width - text.count, 0)) + text
    }
}
