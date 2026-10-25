import CryptoKit
import Foundation
import SkinMuseum

/// The recorded Museum replies under `Fixtures/` (#0126), shared by `SkinMuseumTests` and the app's test configuration (#0194).
public enum MuseumFixtures {
    public static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}

/// A Museum that never touches the network (#0194). GraphQL posts answer `search-zelda` for a search and
/// `skins-page1` otherwise; a GET (a download or a screenshot) answers the bytes of the file in `skinsFolder` whose
/// md5 appears in the URL's path, else 404.
public struct FixtureMuseumTransport: MuseumTransport {
    public let skinsFolder: URL

    public init(skinsFolder: URL) {
        self.skinsFolder = skinsFolder
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        if request.httpMethod == "POST" {
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let name = body.contains("search_classic_skins") ? "search-zelda" : "skins-page1"
            return (try MuseumFixtures.data(name), Self.response(url, 200))
        }
        if let file = matchingFile(for: url) {
            return (try Data(contentsOf: file), Self.response(url, 200))
        }
        return (Data(), Self.response(url, 404))
    }

    private func matchingFile(for url: URL) -> URL? {
        let wanted = Set(
            url.pathComponents.map { ($0 as NSString).deletingPathExtension.lowercased() }
                .filter { $0.count == 32 && $0.allSatisfy(\.isHexDigit) })
        guard !wanted.isEmpty,
            let files = try? FileManager.default.contentsOfDirectory(at: skinsFolder, includingPropertiesForKeys: nil)
        else { return nil }
        return files.first { file in
            guard let data = try? Data(contentsOf: file) else { return false }
            let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return wanted.contains(md5)
        }
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
    }
}
