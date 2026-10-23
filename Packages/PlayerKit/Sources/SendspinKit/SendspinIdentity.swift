import Foundation

/// Roadie's Sendspin player identity. The client id is minted once and kept in `UserDefaults`.
///
/// It is only ever used on the legacy wire: a future encrypted (Noise) client must mint a new id, because MA's
/// downgrade protection refuses a legacy hello for an id that has connected encrypted.
public struct SendspinIdentity: Sendable, Equatable {
    public static let clientIDKey = "sendspin.clientID"

    public var clientID: String
    public var name: String

    public init(clientID: String, name: String) {
        self.clientID = clientID
        self.name = name
    }

    public static func load(defaults: UserDefaults, hostName: String) -> SendspinIdentity {
        let clientID: String
        if let stored = defaults.string(forKey: clientIDKey), !stored.isEmpty {
            clientID = stored
        } else {
            clientID = "roadie-" + UUID().uuidString.lowercased()
            defaults.set(clientID, forKey: clientIDKey)
        }
        return SendspinIdentity(clientID: clientID, name: "Roadie (\(hostName))")
    }
}
