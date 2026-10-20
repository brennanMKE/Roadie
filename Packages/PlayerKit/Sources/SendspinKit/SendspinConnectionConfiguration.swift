import Foundation

public struct SendspinConnectionConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The Music Assistant HTTP base URL (any reverse-proxy prefix kept).
    public var baseURL: URL
    /// The Music Assistant token. Never logged; `description` redacts it.
    public var token: String
    public var clientID: String
    public var name: String
    public var deviceInfo: SendspinDeviceInfo
    public var format: SendspinAudioFormat
    public var bufferCapacity: Int
    public var requiredLeadTimeMs: Int
    public var minBufferMs: Int

    public init(
        baseURL: URL, token: String, clientID: String, name: String, deviceInfo: SendspinDeviceInfo,
        format: SendspinAudioFormat, bufferCapacity: Int = 1_048_576, requiredLeadTimeMs: Int = 300, minBufferMs: Int = 150
    ) {
        self.baseURL = baseURL
        self.token = token
        self.clientID = clientID
        self.name = name
        self.deviceInfo = deviceInfo
        self.format = format
        self.bufferCapacity = bufferCapacity
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
    }

    public var description: String { "SendspinConnectionConfiguration(token: redacted)" }
    public var debugDescription: String { description }

    /// `ws` for `http`, `wss` for `https`; path prefix kept, `/sendspin` appended, query dropped.
    public func sendspinURL() -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/sendspin"
        components.query = nil
        return components.url ?? baseURL
    }

    var hello: SendspinClientHello {
        SendspinClientHello(
            clientID: clientID, name: name, deviceInfo: deviceInfo,
            playerSupport: SendspinPlayerSupport(supportedFormats: [format], bufferCapacity: bufferCapacity))
    }
}
