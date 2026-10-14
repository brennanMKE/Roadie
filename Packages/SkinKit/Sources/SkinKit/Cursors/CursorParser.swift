import Foundation

/// Decodes a Winamp skin cursor file. Returns nil for anything it cannot use; never throws or traps.
public enum CursorParser {
    /// Files larger than this are not cursors.
    static let maxFileSize = 8 * 1024 * 1024

    /// A "RIFF" prefix means an animated cursor saved under the `.cur` name; anything else is an ICO/CUR container
    /// (Webamp skinParserUtils.ts 146-150).
    public static func parse(_ data: Data) -> SkinCursor? {
        guard data.count <= maxFileSize else { return nil }
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("RIFF".utf8)) { return AniParser.parse(bytes) }
        guard let frame = CursorBitmap.decode(bytes) else { return nil }
        return SkinCursor(frames: [frame], steps: [SkinCursor.Step(frame: 0, duration: 0)])
    }
}
