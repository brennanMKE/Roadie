import Foundation

/// The playlist window's colours and font from `pledit.txt`'s `[Text]` section.
public struct PlaylistStyle: Sendable, Hashable {
    /// Text of ordinary rows.
    public var normal: RGBColor
    /// Text of the playing row.
    public var current: RGBColor
    /// List background.
    public var normalBackground: RGBColor
    /// Background of selected rows.
    public var selectedBackground: RGBColor
    /// Windows font name from pledit.txt, e.g. "Arial", "Tempus Sans ITC". The App maps it to an NSFont.
    public var font: String

    public init(
        normal: RGBColor, current: RGBColor, normalBackground: RGBColor, selectedBackground: RGBColor, font: String
    ) {
        self.normal = normal
        self.current = current
        self.normalBackground = normalBackground
        self.selectedBackground = selectedBackground
        self.font = font
    }

    /// Webamp `selectors.ts` `defaultPlaylistStyle`: #00FF00, #FFFFFF, #000000, #0000C6, Arial.
    public static let defaults = PlaylistStyle(
        normal: RGBColor(red: 0x00, green: 0xFF, blue: 0x00),
        current: RGBColor(red: 0xFF, green: 0xFF, blue: 0xFF),
        normalBackground: RGBColor(red: 0x00, green: 0x00, blue: 0x00),
        selectedBackground: RGBColor(red: 0x00, green: 0x00, blue: 0xC6),
        font: "Arial")
}

/// Port of Webamp's `getPlaylistStyle` (skinParserUtils.ts, MIT; see NOTICE): the `[Text]` section of pledit.txt over
/// the defaults, key by key.
enum PlaylistStyleParser {
    static func parse(_ data: Data) -> (style: PlaylistStyle, fallbacks: [String]) {
        parse(text: String(decoding: data, as: UTF8.self))
    }

    static func parse(text: String) -> (style: PlaylistStyle, fallbacks: [String]) {
        guard let section = IniParser.parse(text)["text"] else { return (.defaults, []) }
        var style = PlaylistStyle.defaults
        var fallbacks: [String] = []
        func colour(_ key: String, _ fallback: RGBColor) -> RGBColor {
            guard let value = section[key] else { return fallback }
            if let parsed = hexColour(value) { return parsed }
            fallbacks.append("pledit.txt \(key) '\(value)' unusable; default")
            return fallback
        }
        style.normal = colour("normal", style.normal)
        style.current = colour("current", style.current)
        style.normalBackground = colour("normalbg", style.normalBackground)
        style.selectedBackground = colour("selectedbg", style.selectedBackground)
        if let font = section["font"]?.trimmingCharacters(in: .whitespaces), !font.isEmpty { style.font = font }
        return (style, fallbacks)
    }

    /// Prefixes a missing `#`, cuts to 7 characters, then wants exactly six hex digits.
    static func hexColour(_ value: String) -> RGBColor? {
        var text = value.trimmingCharacters(in: .whitespaces)
        if !text.hasPrefix("#") { text = "#" + text }
        let digits = text.prefix(7).dropFirst()
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let number = UInt32(digits, radix: 16) else { return nil }
        return RGBColor(
            red: UInt8((number >> 16) & 0xFF), green: UInt8((number >> 8) & 0xFF), blue: UInt8(number & 0xFF))
    }
}
