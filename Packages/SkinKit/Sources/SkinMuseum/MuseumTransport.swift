import Foundation

/// The network seam. Tests answer from fixtures; only `URLSessionMuseumTransport` touches URLSession.
public protocol MuseumTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionMuseumTransport: MuseumTransport {
    private let session: URLSession

    public init() {
        session = URLSession(configuration: .ephemeral)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum MuseumUserAgent {
    /// `SkinAmp/<version> (+https://github.com/brennanMKE/SkinAmp)`
    public static func make(version: String) -> String {
        "SkinAmp/\(version) (+https://github.com/brennanMKE/SkinAmp)"
    }
}
