import Foundation

/// Port of Webamp's `parseIni` (js/utils.ts): sections and keys lowercased and trimmed, values cut at a
/// second `=`, trimmed, one leading and one trailing quote stripped. Properties before the first section
/// are ignored; a repeated section name starts over; a repeated key overwrites. A line whose first
/// non-blank character is `;` is a comment; a `//` line is neither a comment nor a section, so a
/// `//[Equalizer]` line is ignored and the properties under it overwrite the current section's values.
enum IniParser {
    static func parse(_ text: String) -> [String: [String: String]] {
        var data: [String: [String: String]] = [:]
        var section: String?
        // Lines split on \r or \n; runs collapse like /[\r\n]+/. Swift treats "\r\n" as one Character.
        let lines = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
        for line in lines {
            if let section, let (key, value) = property(String(line)) {
                data[section]?[key] = value
            } else if let name = sectionName(String(line)) {
                section = name
                data[name] = [:]
            }
        }
        return data
    }

    /// `^\s*\[(.+?)\]\s*$`
    private static func sectionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.first == "[", trimmed.last == "]" else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        return inner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `^\s*([^;][^=]*)\s*=\s*(.*)\s*$`
    private static func property(_ line: String) -> (key: String, value: String)? {
        let body = Substring(line.drop(while: { $0.isWhitespace }))
        guard let first = body.first, first != ";" else { return nil }
        let afterFirst = body.dropFirst()
        guard let equals = afterFirst.firstIndex(of: "=") else { return nil }
        let key = (String(first) + afterFirst[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var value = String(afterFirst[afterFirst.index(after: equals)...])
        if let second = value.firstIndex(of: "=") { value = String(value[..<second]) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, stripQuotes(value))
    }

    /// `.replace(/(^")|("$)|(^')|('$)/g, "")`: at most one leading and one trailing quote.
    private static func stripQuotes(_ value: String) -> String {
        var characters = Substring(value)
        let isQuote: (Character) -> Bool = { $0 == "\"" || $0 == "'" }
        if characters.count == 1, let only = characters.first, isQuote(only) { return "" }
        if let first = characters.first, isQuote(first) { characters = characters.dropFirst() }
        if let last = characters.last, isQuote(last) { characters = characters.dropLast() }
        return String(characters)
    }
}
