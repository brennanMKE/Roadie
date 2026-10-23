import Foundation

// Legacy (unencrypted) Sendspin wire, as aiosendspin 9.1.1 speaks it. Shapes: docs/sendspin-notes.md sections 3 to 6.

// MARK: - Outgoing

public struct SendspinAudioFormat: Codable, Sendable, Equatable {
    public var codec: String
    public var channels: Int
    public var sampleRate: Int
    public var bitDepth: Int

    public init(codec: String = "pcm", channels: Int = 2, sampleRate: Int, bitDepth: Int = 16) {
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    enum CodingKeys: String, CodingKey {
        case codec, channels
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
    }
}

public struct SendspinDeviceInfo: Codable, Sendable, Equatable {
    public var productName: String
    public var manufacturer: String
    public var softwareVersion: String

    public init(productName: String = "Roadie", manufacturer: String = "Roadie", softwareVersion: String) {
        self.productName = productName
        self.manufacturer = manufacturer
        self.softwareVersion = softwareVersion
    }

    enum CodingKeys: String, CodingKey {
        case manufacturer
        case productName = "product_name"
        case softwareVersion = "software_version"
    }
}

public struct SendspinPlayerSupport: Codable, Sendable, Equatable {
    public var supportedFormats: [SendspinAudioFormat]
    public var bufferCapacity: Int
    public var supportedCommands: [String]

    public init(supportedFormats: [SendspinAudioFormat], bufferCapacity: Int, supportedCommands: [String] = ["volume", "mute"]) {
        self.supportedFormats = supportedFormats
        self.bufferCapacity = bufferCapacity
        self.supportedCommands = supportedCommands
    }

    enum CodingKeys: String, CodingKey {
        case supportedFormats = "supported_formats"
        case bufferCapacity = "buffer_capacity"
        case supportedCommands = "supported_commands"
    }
}

public struct SendspinClientHello: Codable, Sendable, Equatable {
    public var clientID: String
    public var name: String
    public var version: Int = 1
    public var supportedRoles: [String] = ["player@v1"]
    public var deviceInfo: SendspinDeviceInfo
    public var playerSupport: SendspinPlayerSupport

    public init(clientID: String, name: String, deviceInfo: SendspinDeviceInfo, playerSupport: SendspinPlayerSupport) {
        self.clientID = clientID
        self.name = name
        self.deviceInfo = deviceInfo
        self.playerSupport = playerSupport
    }

    enum CodingKeys: String, CodingKey {
        case name, version
        case clientID = "client_id"
        case supportedRoles = "supported_roles"
        case deviceInfo = "device_info"
        case playerSupport = "player@v1_support"
    }
}

public struct SendspinClientTime: Codable, Sendable, Equatable {
    public var clientTransmitted: Int64
    public init(clientTransmitted: Int64) { self.clientTransmitted = clientTransmitted }
    enum CodingKeys: String, CodingKey { case clientTransmitted = "client_transmitted" }
}

public struct SendspinPlayerState: Codable, Sendable, Equatable {
    public var volume: Int
    public var muted: Bool
    public var staticDelayMs: Int = 0
    public var requiredLeadTimeMs: Int
    public var minBufferMs: Int
    public var supportedCommands: [String] = []

    public init(volume: Int, muted: Bool, requiredLeadTimeMs: Int, minBufferMs: Int) {
        self.volume = min(max(volume, 0), 100)
        self.muted = muted
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
    }

    enum CodingKeys: String, CodingKey {
        case volume, muted
        case staticDelayMs = "static_delay_ms"
        case requiredLeadTimeMs = "required_lead_time_ms"
        case minBufferMs = "min_buffer_ms"
        case supportedCommands = "supported_commands"
    }
}

public struct SendspinClientState: Codable, Sendable, Equatable {
    public var available: Bool
    public var player: SendspinPlayerState
    public init(available: Bool, player: SendspinPlayerState) {
        self.available = available
        self.player = player
    }
}

public enum SendspinGoodbyeReason: String, Codable, Sendable {
    case shutdown, restart
    case userRequest = "user_request"
    case anotherServer = "another_server"
}

public struct SendspinClientGoodbye: Codable, Sendable, Equatable {
    public var reason: SendspinGoodbyeReason
    public init(reason: SendspinGoodbyeReason) { self.reason = reason }
}

// MARK: - Incoming

public struct SendspinServerHello: Codable, Sendable, Equatable {
    public var serverID: String
    public var name: String
    public var version: Int
    public var activeRoles: [String]
    public var connectionReason: String?

    enum CodingKeys: String, CodingKey {
        case name, version
        case serverID = "server_id"
        case activeRoles = "active_roles"
        case connectionReason = "connection_reason"
    }
}

public struct SendspinServerTime: Codable, Sendable, Equatable {
    public var clientTransmitted: Int64
    public var serverReceived: Int64
    public var serverTransmitted: Int64

    public init(clientTransmitted: Int64, serverReceived: Int64, serverTransmitted: Int64) {
        self.clientTransmitted = clientTransmitted
        self.serverReceived = serverReceived
        self.serverTransmitted = serverTransmitted
    }

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
        case serverReceived = "server_received"
        case serverTransmitted = "server_transmitted"
    }
}

public struct SendspinStreamFormat: Codable, Sendable, Equatable {
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    public var bitDepth: Int
    public var codecHeader: String?

    enum CodingKeys: String, CodingKey {
        case codec, channels
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case codecHeader = "codec_header"
    }
}

public struct SendspinStreamStart: Codable, Sendable, Equatable {
    public var serverTransmitted: Int64?
    public var player: SendspinStreamFormat?
    enum CodingKeys: String, CodingKey {
        case player
        case serverTransmitted = "server_transmitted"
    }
}

public struct SendspinStreamClear: Codable, Sendable, Equatable {
    public var roles: [String]?
}

public struct SendspinStreamEnd: Codable, Sendable, Equatable {
    public var roles: [String]?
}

public struct SendspinGroupUpdate: Codable, Sendable, Equatable {
    public var playbackState: String?
    public var groupID: String?
    public var groupName: String?
    enum CodingKeys: String, CodingKey {
        case playbackState = "playback_state"
        case groupID = "group_id"
        case groupName = "group_name"
    }
}

public enum SendspinCommandKind: Codable, Sendable, Equatable {
    case volume, mute, setStaticDelay
    case other(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "volume": self = .volume
        case "mute": self = .mute
        case "set_static_delay": self = .setStaticDelay
        default: self = .other(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .volume: try container.encode("volume")
        case .mute: try container.encode("mute")
        case .setStaticDelay: try container.encode("set_static_delay")
        case .other(let raw): try container.encode(raw)
        }
    }
}

public struct SendspinPlayerCommand: Codable, Sendable, Equatable {
    public var command: SendspinCommandKind
    public var volume: Int?
    public var mute: Bool?
    public var staticDelayMs: Int?
    enum CodingKeys: String, CodingKey {
        case command, volume, mute
        case staticDelayMs = "static_delay_ms"
    }
}

public struct SendspinServerCommand: Codable, Sendable, Equatable {
    public var player: SendspinPlayerCommand?
}

public enum SendspinIncoming: Sendable, Equatable {
    case serverHello(SendspinServerHello)
    case serverTime(SendspinServerTime)
    case streamStart(SendspinStreamStart)
    case streamClear(SendspinStreamClear)
    case streamEnd(SendspinStreamEnd)
    case groupUpdate(SendspinGroupUpdate)
    case serverCommand(SendspinServerCommand)
    case ignored(type: String)

    private struct TypeOnly: Decodable { var type: String }
    private struct Envelope<P: Decodable>: Decodable { var payload: P }
    private struct EmptyPayload: Decodable {}

    /// Unknown types and fields are ignored (spec forward-compatibility); a known type that does not decode throws.
    public static func decode(_ text: String) throws -> SendspinIncoming {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        guard let type = try? decoder.decode(TypeOnly.self, from: data).type else {
            throw SendspinError.malformed(type: "unknown")
        }
        func payload<P: Decodable>(_: P.Type) throws -> P {
            do {
                return try decoder.decode(Envelope<P>.self, from: data).payload
            } catch {
                throw SendspinError.malformed(type: type)
            }
        }
        switch type {
        case "server/hello": return .serverHello(try payload(SendspinServerHello.self))
        case "server/time": return .serverTime(try payload(SendspinServerTime.self))
        case "stream/start": return .streamStart(try payload(SendspinStreamStart.self))
        case "stream/clear": return .streamClear((try? decoder.decode(Envelope<SendspinStreamClear>.self, from: data).payload) ?? SendspinStreamClear())
        case "stream/end": return .streamEnd((try? decoder.decode(Envelope<SendspinStreamEnd>.self, from: data).payload) ?? SendspinStreamEnd())
        case "group/update": return .groupUpdate(try payload(SendspinGroupUpdate.self))
        case "server/command": return .serverCommand(try payload(SendspinServerCommand.self))
        default: return .ignored(type: type)
        }
    }
}

// MARK: - Encoding

public enum SendspinOutgoing {
    private struct Envelope<P: Encodable>: Encodable {
        var type: String
        var payload: P
    }

    /// `{"type": …, "payload": …}` with sorted keys, so tests can compare strings.
    public static func encode<P: Encodable>(type: String, payload: P) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Envelope(type: type, payload: payload))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public static func encode(_ hello: SendspinClientHello) -> String { encode(type: "client/hello", payload: hello) }
    public static func encode(_ time: SendspinClientTime) -> String { encode(type: "client/time", payload: time) }
    public static func encode(_ state: SendspinClientState) -> String { encode(type: "client/state", payload: state) }
    public static func encode(_ goodbye: SendspinClientGoodbye) -> String { encode(type: "client/goodbye", payload: goodbye) }

    /// The proxy's auth frame. Built only here; never logged.
    static func authFrame(token: String, clientID: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(["type": "auth", "token": token, "client_id": clientID])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
