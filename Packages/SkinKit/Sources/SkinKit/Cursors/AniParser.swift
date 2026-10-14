import Foundation

/// Decodes a RIFF `ACON` animated cursor (what Winamp skins ship under the `.cur` name). Webamp's ani-cursor
/// parser.ts / index.ts are the reference. Never traps: every read is bounds-checked and counts are capped.
enum AniParser {
    static let maxFrames = 256
    static let maxSteps = 1024
    static let maxDepth = 4

    private struct Header {
        var frames = 0, steps = 0, dispRate = 0, flags: UInt32 = 0
    }

    private struct Collected {
        var header: Header?
        var rate: [UInt32]?
        var seq: [UInt32]?
        var icons: [ClosedRange<Int>] = []
    }

    static func parse(_ bytes: [UInt8]) -> SkinCursor? {
        var reader = ByteReader(bytes)
        guard let riff = reader.bytes(4), riff == Array("RIFF".utf8), let size = reader.u32(),
              let form = reader.bytes(4), form == Array("ACON".utf8)
        else { return nil }
        let end = min(8 + Int(size), bytes.count)
        var collected = Collected()
        guard walk(bytes, from: 12, to: end, inFram: false, depth: 0, into: &collected) else { return nil }
        guard let header = collected.header, header.flags & 1 != 0, !collected.icons.isEmpty else { return nil }

        // Frames that fail to decode are dropped, and so is every step that points at them.
        var frames: [SkinCursor.Frame] = []
        var remap: [Int: Int] = [:]
        for (index, range) in collected.icons.enumerated() {
            if let frame = CursorBitmap.decode(Array(bytes[range])) {
                remap[index] = frames.count
                frames.append(frame)
            }
        }
        guard !frames.isEmpty else { return nil }

        let stepCount = min(max(header.steps > 0 ? header.steps : collected.icons.count, 1), maxSteps)
        var steps: [SkinCursor.Step] = []
        for i in 0..<stepCount {
            let original = i < (collected.seq?.count ?? 0) ? Int(collected.seq![i]) : i
            guard let frame = remap[original] else { continue }
            let jiffies = i < (collected.rate?.count ?? 0) ? Int(collected.rate![i]) : header.dispRate
            steps.append(SkinCursor.Step(frame: frame, duration: Double(max(jiffies, 1)) / 60))
        }
        guard !steps.isEmpty else { return nil }
        return SkinCursor(frames: frames, steps: steps)
    }

    /// Walks the chunks in `from..<to`; false when a chunk claims more than the data holds.
    private static func walk(
        _ bytes: [UInt8], from: Int, to: Int, inFram: Bool, depth: Int, into collected: inout Collected
    ) -> Bool {
        guard depth <= maxDepth else { return false }
        var reader = ByteReader(bytes)
        var position = from
        while position + 8 <= to {
            guard reader.seek(to: position), let idBytes = reader.bytes(4), let size32 = reader.u32() else { return false }
            let id = String(decoding: idBytes, as: UTF8.self)
            let bodyStart = position + 8
            let size = Int(size32)
            guard size <= to - bodyStart else { return false }
            let bodyEnd = bodyStart + size
            switch id {
            case "LIST":
                guard size >= 4, let form = reader.bytes(4) else { return false }
                let isFram = String(decoding: form, as: UTF8.self) == "fram"
                guard walk(bytes, from: bodyStart + 4, to: bodyEnd, inFram: isFram, depth: depth + 1, into: &collected)
                else { return false }
            case "anih":
                if size >= 36, collected.header == nil {
                    _ = reader.u32()                       // cbSize
                    let frames = reader.u32() ?? 0, steps = reader.u32() ?? 0
                    _ = reader.u32(); _ = reader.u32(); _ = reader.u32(); _ = reader.u32()   // width, height, bits, planes
                    let rate = reader.u32() ?? 0, flags = reader.u32() ?? 0
                    collected.header = Header(
                        frames: Int(frames), steps: Int(min(steps, UInt32(maxSteps))), dispRate: Int(min(rate, 1 << 24)),
                        flags: flags)
                }
            case "rate", "seq ":
                var values: [UInt32] = []
                for _ in 0..<min(size / 4, maxSteps) { if let v = reader.u32() { values.append(v) } }
                if id == "rate" { collected.rate = values } else { collected.seq = values }
            case "icon":
                if inFram, collected.icons.count < maxFrames, size > 0 { collected.icons.append(bodyStart...bodyEnd - 1) }
            default:
                break
            }
            position = bodyEnd + (size & 1)
        }
        return true
    }
}
