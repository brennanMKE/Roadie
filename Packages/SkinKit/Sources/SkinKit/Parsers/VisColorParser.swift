import Foundation

public struct RGBColor: Sendable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
}

/// Parses `viscolor.txt`: 24 lines of `r,g,b` with optional `//` comments.
enum VisColorParser {
    static func parse(_ data: Data) -> [RGBColor] {
        let text = String(decoding: data, as: UTF8.self)
        var colors: [RGBColor] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let values = line
                .split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let numbers = values
                .split(whereSeparator: { !$0.isNumber })
                .prefix(3)
                .compactMap { Int($0) }
                .map { UInt8(clamping: $0) }
            guard numbers.count == 3 else { continue }
            colors.append(RGBColor(red: numbers[0], green: numbers[1], blue: numbers[2]))
            if colors.count == 24 { break }
        }
        return colors
    }
}
