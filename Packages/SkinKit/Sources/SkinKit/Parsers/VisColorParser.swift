import Foundation

public struct RGBColor: Sendable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Parses `viscolor.txt`, ported from Webamp's `parseViscolors` (js/utils.ts, MIT; see NOTICE).
enum VisColorParser {
    /// Webamp DEFAULT_SKIN.colors (packages/webamp/js/baseSkin.json), the classic base skin's viscolor.txt.
    /// 0 background, 1 grid dots, 2-17 spectrum top to bottom, 18-22 oscilloscope, 23 peak dots.
    static let defaults: [RGBColor] = [
        (0, 0, 0), (24, 33, 41), (239, 49, 16), (206, 41, 16), (214, 90, 0), (214, 102, 0),
        (214, 115, 0), (198, 123, 8), (222, 165, 24), (214, 181, 33), (189, 222, 41), (148, 222, 33),
        (41, 206, 16), (50, 190, 16), (57, 181, 16), (49, 156, 8), (41, 148, 0), (24, 132, 8),
        (255, 255, 255), (214, 214, 222), (181, 189, 189), (160, 170, 175), (148, 156, 165), (150, 150, 150),
    ].map { RGBColor(red: $0.0, green: $0.1, blue: $0.2) }

    /// The i-th line matching ^\s*(\d+)\s*,?\s*(\d+)\s*,?\s*(\d+) replaces index i of `defaults`; other lines
    /// are skipped without consuming an index; lines past 24 are ignored (Webamp keeps them, nothing reads
    /// them); values clamp to 0...255 (Webamp does not). Always 24 entries.
    static func parse(_ data: Data) -> [RGBColor] {
        parseCounted(data).colors
    }

    static func parseCounted(_ data: Data) -> (colors: [RGBColor], parsedCount: Int) {
        let text = String(decoding: data, as: UTF8.self)
        var colors = defaults
        var count = 0
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }
        for line in lines {
            guard count < colors.count,
                  let match = line.firstMatch(of: /^\s*(\d+)\s*,?\s*(\d+)\s*,?\s*(\d+)/)
            else { continue }
            func value(_ s: Substring) -> UInt8 { UInt8(clamping: Int(s) ?? Int(UInt8.max)) }
            colors[count] = RGBColor(red: value(match.1), green: value(match.2), blue: value(match.3))
            count += 1
        }
        return (colors, count)
    }
}
