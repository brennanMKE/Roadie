import Foundation

/// One inbound message, classified. The rules come from `docs/ma-protocol-notes.md` section 3.
enum MAEnvelope: Sendable {
    case serverInfo(MAServerInfo)
    case result(messageID: String, result: MAJSON, partial: Bool)
    case error(messageID: String, code: Int, details: String)
    case event(MAServerEvent)
    case unknown

    static func parse(_ text: String) -> MAEnvelope {
        guard let json = try? MAJSON.parse(text), case .object(let object) = json else { return .unknown }
        if let id = messageID(object["message_id"]) {
            if let code = object["error_code"]?.intValue {
                return .error(messageID: id, code: code, details: object["details"]?.stringValue ?? "")
            }
            if let result = object["result"] {
                return .result(messageID: id, result: result, partial: object["partial"]?.boolValue ?? false)
            }
            return .unknown
        }
        if object["server_id"] != nil, object["schema_version"] != nil {
            if let info = try? json.decode(as: MAServerInfo.self) { return .serverInfo(info) }
            return .unknown
        }
        if let event = MAServerEvent(json: json) { return .event(event) }
        return .unknown
    }

    private static func messageID(_ value: MAJSON?) -> String? {
        switch value {
        case .string(let text)?: text
        case .number(let number)?: Int(exactly: number).map(String.init)
        default: nil
        }
    }
}
