import Foundation

/// A bounds-checked little-endian reader over a copied byte array. Every read returns nil past the end; nothing traps.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var position: Int

    init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var remaining: Int { max(bytes.count - position, 0) }

    mutating func seek(to offset: Int) -> Bool {
        guard offset >= 0, offset <= bytes.count else { return false }
        position = offset
        return true
    }

    mutating func u8() -> UInt8? {
        guard position >= 0, position < bytes.count else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func u16() -> UInt16? {
        guard let lo = u8(), let hi = u8() else { return nil }
        return UInt16(lo) | UInt16(hi) << 8
    }

    mutating func u32() -> UInt32? {
        guard let lo = u16(), let hi = u16() else { return nil }
        return UInt32(lo) | UInt32(hi) << 16
    }

    mutating func i32() -> Int32? {
        u32().map { Int32(bitPattern: $0) }
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, count <= remaining else { return nil }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    /// Bit `index` of a 1-bpp row, most significant bit first. Out-of-range reads give 0.
    static func bit(_ index: Int, in bytes: [UInt8], rowStart: Int) -> Bool {
        let byteIndex = rowStart + index / 8
        guard index >= 0, byteIndex >= 0, byteIndex < bytes.count else { return false }
        return bytes[byteIndex] & (0x80 >> UInt8(index % 8)) != 0
    }
}
