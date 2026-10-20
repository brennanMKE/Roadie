import Foundation

public struct SendspinAudioChunk: Sendable, Equatable {
    /// Server time (µs) at which the chunk's first frame must leave the audio port.
    public var serverMicros: Int64
    public var payload: Data

    public init(serverMicros: Int64, payload: Data) {
        self.serverMicros = serverMicros
        self.payload = payload
    }
}

/// The wire flavour. Only the legacy unencrypted wire exists today.
///
/// Spec `main` (encrypted wire) uses a 13-byte audio header: type byte, int64 BE timestamp, then a uint32 BE
/// `send_ahead` at bytes 9…12. Add it as a new case when the Noise wire is implemented; not supported now.
public enum SendspinWire: Sendable {
    case legacy

    public var audioHeaderLength: Int {
        switch self {
        case .legacy: 9
        }
    }

    static let audioMessageType: UInt8 = 4

    /// Returns nil for binary messages that are not audio (ignored); throws when an audio message is too short.
    public static func parseAudioChunk(_ data: Data, wire: SendspinWire = .legacy) throws -> SendspinAudioChunk? {
        let bytes = [UInt8](data)
        guard let first = bytes.first, first == audioMessageType else { return nil }
        guard bytes.count >= wire.audioHeaderLength else { throw SendspinError.malformed(type: "audio") }
        var raw: UInt64 = 0
        for index in 1...8 { raw = raw << 8 | UInt64(bytes[index]) }
        return SendspinAudioChunk(serverMicros: Int64(bitPattern: raw), payload: Data(bytes[wire.audioHeaderLength...]))
    }
}
