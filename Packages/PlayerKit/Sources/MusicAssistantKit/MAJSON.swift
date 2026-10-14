import Foundation

/// A JSON value: the type of request `args`, raw results and event `data`. Foundation only.
public indirect enum MAJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MAJSON])
    case object([String: MAJSON])
}

extension MAJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([MAJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: MAJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension MAJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: MAJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, MAJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension MAJSON {
    /// Parses one JSON document (a fragment is fine).
    public static func parse(_ data: Data) throws -> MAJSON {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return MAJSON(any: any)
    }

    public static func parse(_ text: String) throws -> MAJSON {
        try parse(Data(text.utf8))
    }

    private init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { MAJSON(any: $0) })
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { MAJSON(any: $0) })
        default:
            self = .null
        }
    }

    public subscript(key: String) -> MAJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> MAJSON? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var isNull: Bool { if case .null = self { true } else { false } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var doubleValue: Double? { if case .number(let value) = self { value } else { nil } }
    public var intValue: Int? { if case .number(let value) = self { Int(exactly: value) } else { nil } }
    public var arrayValue: [MAJSON]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: [String: MAJSON]? { if case .object(let value) = self { value } else { nil } }

    /// Compact JSON with sorted keys; whole numbers print without a fraction ("12", not "12.0").
    public func encodedString() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value):
            if !value.isFinite {
                out += "null"
            } else if value == value.rounded(), abs(value) < 1e15 {
                out += String(Int64(value))
            } else {
                out += "\(value)"
            }
        case .string(let value): Self.writeString(value, to: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(to: &out)
            }
            out += "]"
        case .object(let values):
            out += "{"
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                values[key]?.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ string: String, to out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Decodes this value into `T`.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(encodedString().utf8))
    }
}
