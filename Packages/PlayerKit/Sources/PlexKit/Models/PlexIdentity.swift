import Foundation

public struct PlexIdentity: Codable, Hashable, Sendable {
    public var machineIdentifier: String
    public var version: String

    public init(machineIdentifier: String, version: String) {
        self.machineIdentifier = machineIdentifier
        self.version = version
    }
}
