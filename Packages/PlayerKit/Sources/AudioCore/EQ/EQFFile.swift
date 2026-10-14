import Foundation

/// Winamp `.eqf` (and `.q1`) preset files. A port of Webamp's winamp-eqf package (parser.ts, creator.ts; MIT, see NOTICE):
/// the header "Winamp EQ library file v1.1", a ctrl-Z and "!--", then per preset a 257-byte NUL-padded name and
/// 11 bytes (ten bands from 60 Hz up, then the preamp), each stored as `64 - value` with Winamp's 1...64 slider value.
public enum EQFFile {
    public static let header = "Winamp EQ library file v1.1"
    public enum ParseError: Error, Equatable { case invalidHeader, truncated }

    private static let preambleLength = 31
    private static let nameLength = 257
    private static let presetLength = 268

    /// Every preset in the file, in order. Names are Windows-1252, decoded lossily to String. Unlike Webamp, a file
    /// that ends inside a preset is refused rather than read as `undefined`.
    public static func parse(_ data: Data) throws -> [EQPreset] {
        let bytes = [UInt8](data)
        guard bytes.count >= preambleLength, bytes.prefix(header.utf8.count).elementsEqual(header.utf8) else {
            throw ParseError.invalidHeader
        }
        var presets: [EQPreset] = []
        var offset = preambleLength
        while offset < bytes.count {
            guard offset + presetLength <= bytes.count else { throw ParseError.truncated }
            let nameBytes = bytes[offset..<(offset + nameLength)].prefix { $0 != 0 }
            let name = String(bytes: nameBytes, encoding: .windowsCP1252) ?? String(decoding: nameBytes, as: UTF8.self)
            let values = (0..<11).map { 64 - Int(bytes[offset + nameLength + $0]) }
            presets.append(EQPreset(
                name: name, preamp: EQPreset.decibels(fromWinampValue: values[10]),
                gains: values.prefix(10).map(EQPreset.decibels(fromWinampValue:))))
            offset += presetLength
        }
        return presets
    }

    /// One or more presets; names longer than 256 bytes are cut.
    public static func serialize(_ presets: [EQPreset]) -> Data {
        var bytes = Array(header.utf8) + [0x1A] + Array("!--".utf8)
        for preset in presets {
            let name = Array((preset.name.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()).prefix(nameLength - 1))
            bytes += name + [UInt8](repeating: 0, count: nameLength - name.count)
            for db in preset.gains + [preset.preamp] {
                bytes.append(UInt8(64 - EQPreset.winampValue(fromDecibels: db)))
            }
        }
        return Data(bytes)
    }
}
