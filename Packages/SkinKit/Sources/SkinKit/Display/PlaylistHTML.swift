import Foundation

/// Winamp's "Generate HTML Playlist" page (after Webamp's `js/playlistHtml.tsx`): track count, average and total length,
/// and a numbered list of names with durations. Plain HTML with inline CSS, no scripts.
public enum PlaylistHTML {
    public struct Entry: Equatable, Sendable {
        /// Already run through `PlaylistText.displayName`.
        public var name: String
        public var duration: TimeInterval?

        public init(name: String, duration: TimeInterval?) {
            self.name = name
            self.duration = duration
        }
    }

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    public static func document(entries: [Entry]) -> String {
        let known = entries.compactMap(\.duration).filter { $0.isFinite && $0 >= 0 }
        let total = known.reduce(0, +)
        let average = known.isEmpty ? 0 : total / Double(known.count)
        let count = entries.count
        let items = entries.enumerated().map { index, entry -> String in
            let time = PlaylistText.time(entry.duration)
            let suffix = time.isEmpty ? "" : " (\(time))"
            return "<li>\(index + 1). \(escape(entry.name))\(suffix)</li>"
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>Roadie Generated PlayList</title>
        <style>
        body { background: #000040; color: #4040FF; font-family: Arial, sans-serif; }
        .h { color: #FFFFFF; font-size: 32px; }
        .t { color: #FFFFFF; }
        ol { list-style: none; padding-left: 0; color: #4040FF; }
        </style>
        </head>
        <body>
        <div class="h">Roadie Generated PlayList</div>
        <p><span class="t">\(count)</span> track\(count == 1 ? "" : "s") in playlist, average track length: \
        <span class="t">\(PlaylistText.time(average))</span></p>
        <p>Playlist length: <span class="t">\(PlaylistText.time(total))</span></p>
        <p class="t">Playlist files:</p>
        <ol>
        \(items)
        </ol>
        </body>
        </html>

        """
    }
}
