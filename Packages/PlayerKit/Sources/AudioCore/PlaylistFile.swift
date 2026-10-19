import Foundation

/// Winamp playlist files: M3U / extended M3U, M3U8 (UTF-8) and PLS v2. Parsing never throws for content; entries
/// are returned in file order.
public enum PlaylistFile {
    public enum Format: Sendable, Equatable { case m3u, pls }

    public struct Entry: Equatable, Sendable {
        /// As written, trimmed.
        public var location: String
        /// `#EXTINF` display text or `TitleN`.
        public var title: String?
        /// Seconds; nil for -1 or missing.
        public var duration: Int?

        public init(location: String, title: String? = nil, duration: Int? = nil) {
            self.location = location
            self.title = title
            self.duration = duration
        }
    }

    public enum Resolved: Equatable, Sendable {
        case file(URL)
        case skip(location: String, reason: String)
    }

    public static let fileExtensions: Set<String> = ["m3u", "m3u8", "pls"]

    public static func isPlaylist(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    public static func format(for url: URL, data: Data) -> Format {
        let text = decode(data, pathExtension: url.pathExtension)
        let firstLine = lines(text).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if firstLine?.lowercased() == "[playlist]" { return .pls }
        return url.pathExtension.lowercased() == "pls" ? .pls : .m3u
    }

    /// UTF-8 (BOM stripped), or UTF-16 LE/BE when it starts with a BOM; otherwise `.m3u8` decodes lossily as
    /// UTF-8 and other extensions fall back to Windows-1252. BOM-less UTF-16 and UTF-32 are not detected.
    public static func decode(_ data: Data, pathExtension: String) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        } else if bytes.starts(with: [0xFF, 0xFE]),
                  let text = String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) {
            return text
        } else if bytes.starts(with: [0xFE, 0xFF]),
                  let text = String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) {
            return text
        }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if pathExtension.lowercased() != "m3u8", let text = String(data: bytes, encoding: .windowsCP1252) {
            return text
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func parse(_ data: Data, format: Format, pathExtension: String = "m3u") -> [Entry] {
        let text = decode(data, pathExtension: pathExtension)
        switch format {
        case .m3u: return parseM3U(text)
        case .pls: return parsePLS(text)
        }
    }

    public static func resolve(_ entry: Entry, relativeTo playlistURL: URL) -> Resolved {
        let location = entry.location
        let folder = playlistURL.deletingLastPathComponent()
        let url: URL
        if let scheme = urlScheme(of: location) {
            guard scheme == "file", let fileURL = URL(string: location), fileURL.isFileURL else {
                return .skip(location: location, reason: "streams are not supported")
            }
            url = fileURL.standardizedFileURL
        } else if location.hasPrefix("/") {
            url = URL(filePath: location).standardizedFileURL
        } else {
            let path = location.replacingOccurrences(of: "\\", with: "/")
            url = URL(filePath: path, relativeTo: folder).absoluteURL.standardizedFileURL
        }
        if isPlaylist(url) { return .skip(location: location, reason: "nested playlist") }
        return .file(url)
    }

    /// Writes the `.file` tracks; `skipped` counts the others (server tracks have no local path).
    public static func serialize(_ tracks: [Track], format: Format, playlistURL: URL) -> (data: Data, written: Int, skipped: Int) {
        let folderPath = playlistURL.deletingLastPathComponent().standardizedFileURL.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        var rows: [(path: String, title: String, seconds: Int)] = []
        var skipped = 0
        for track in tracks {
            guard case .file(let url) = track.source else {
                skipped += 1
                continue
            }
            let path = url.standardizedFileURL.path
            let written = path.hasPrefix(prefix) ? escapedRelative(String(path.dropFirst(prefix.count))) : path
            let title = track.artist.isEmpty ? track.title : "\(track.artist) - \(track.title)"
            let seconds = track.duration > 0 ? Int(track.duration.rounded()) : -1
            rows.append((written, title, seconds))
        }
        var out: [String] = []
        switch format {
        case .m3u:
            out.append("#EXTM3U")
            for row in rows {
                out.append("#EXTINF:\(row.seconds),\(row.title)")
                out.append(row.path)
            }
        case .pls:
            out.append("[playlist]")
            for (i, row) in rows.enumerated() {
                out.append("File\(i + 1)=\(row.path)")
                out.append("Title\(i + 1)=\(row.title)")
                out.append("Length\(i + 1)=\(row.seconds)")
            }
            out.append("NumberOfEntries=\(rows.count)")
            out.append("Version=2")
        }
        return (Data((out.joined(separator: "\n") + "\n").utf8), rows.count, skipped)
    }

    // MARK: Private

    /// The lowercased scheme when `location` is a URL: `scheme://…` (RFC 3986 scheme of two or more characters) or
    /// `file:…`. Anything else, such as `AC:DC - x.mp3`, is a path.
    private static func urlScheme(of location: String) -> String? {
        if location.lowercased().hasPrefix("file:") { return "file" }
        guard let range = location.range(of: "://") else { return nil }
        let scheme = location[..<range.lowerBound]
        guard scheme.count > 1, let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return nil }
        return scheme.lowercased()
    }

    /// Prefixes `./` when a relative path would otherwise read back as a comment (`#`), get trimmed (leading
    /// whitespace) or look like a URL scheme to other players (a `:` in its first component).
    private static func escapedRelative(_ path: String) -> String {
        let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard path.hasPrefix("#") || path.first?.isWhitespace == true || first.contains(":") else { return path }
        return "./" + path
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func seconds(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return value
    }

    private static func parseM3U(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var pending: (title: String?, duration: Int?)?
        for raw in lines(text) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.uppercased().hasPrefix("#EXTINF:") {
                    let body = line.dropFirst("#EXTINF:".count)
                    if let comma = body.firstIndex(of: ",") {
                        let title = body[body.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                        pending = (title.isEmpty ? nil : title, seconds(String(body[..<comma])))
                    } else {
                        pending = (nil, seconds(String(body)))
                    }
                }
                continue
            }
            entries.append(Entry(location: line, title: pending?.title, duration: pending?.duration))
            pending = nil
        }
        return entries
    }

    private static func parsePLS(_ text: String) -> [Entry] {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var lengths: [Int: Int] = [:]
        var inPlaylist = false
        for raw in lines(text) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                inPlaylist = line.lowercased() == "[playlist]"
                continue
            }
            guard inPlaylist, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            for (name, apply) in [
                ("file", { (n: Int) in files[n] = value }),
                ("title", { (n: Int) in titles[n] = value }),
                ("length", { (n: Int) in if let s = seconds(value) { lengths[n] = s } }),
            ] where key.hasPrefix(name) {
                if let n = Int(key.dropFirst(name.count)) { apply(n) }
            }
        }
        return files.keys.sorted().compactMap { n in
            guard let location = files[n], !location.isEmpty else { return nil }
            let title = titles[n].flatMap { $0.isEmpty ? nil : $0 }
            return Entry(location: location, title: title, duration: lengths[n])
        }
    }
}
