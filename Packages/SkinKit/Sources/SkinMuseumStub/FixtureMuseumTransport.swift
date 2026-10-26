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

/// A Museum that never touches the network (#0194). GraphQL posts answer `search-zelda` for a search and `skins-page1`
/// otherwise; a GET (a download or a screenshot) answers the bytes of the file in `skinsFolder` whose md5 appears in
/// the URL's path, else 404.
///
/// With `featuredSkin` (the app's `-RoadieMuseumFeatured <name>`, #0208), the browse page's first row is rewritten to
/// `<featuredSkin>.wsz` in `skinsFolder`: its md5, `<name>_[S0].wsz` and URLs carrying that md5, so a download succeeds
/// with real, checksum-matching bytes. The recorded rows name Museum skins nobody caches.
public struct FixtureMuseumTransport: MuseumTransport {
    public let skinsFolder: URL
    /// A `.wsz` file name in `skinsFolder` without the extension, or nil to serve the page as recorded.
    public let featuredSkin: String?

    public init(skinsFolder: URL, featuredSkin: String? = nil) {
        self.skinsFolder = skinsFolder
        self.featuredSkin = featuredSkin
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        if request.httpMethod == "POST" {
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard body.contains("search_classic_skins") else {
                return (try featuring(MuseumFixtures.data("skins-page1")), Self.response(url, 200))
            }
            return (try MuseumFixtures.data("search-zelda"), Self.response(url, 200))
        }
        if let file = matchingFile(for: url) {
            return (try Data(contentsOf: file), Self.response(url, 200))
        }
        return (Data(), Self.response(url, 404))
    }

    /// `page` with its first node replaced by `featuredSkin`, when it is set and its file reads.
    private func featuring(_ page: Data) throws -> Data {
        guard let featuredSkin else { return page }
        let file = skinsFolder.appending(path: "\(featuredSkin).wsz", directoryHint: .notDirectory)
        guard let bytes = try? Data(contentsOf: file),
            var json = try JSONSerialization.jsonObject(with: page) as? [String: Any],
            var data = json["data"] as? [String: Any], var skins = data["skins"] as? [String: Any],
            var nodes = skins["nodes"] as? [[String: Any]], !nodes.isEmpty
        else { return page }
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let stem = file.deletingPathExtension().lastPathComponent
        nodes[0]["md5"] = md5
        nodes[0]["filename"] = "\(stem)_[S0].wsz"
        nodes[0]["nsfw"] = false
        nodes[0]["museum_url"] = "https://skins.webamp.org/skin/\(md5)"
        nodes[0]["screenshot_url"] = "https://r2.webampskins.org/screenshots/\(md5).png"
        nodes[0]["download_url"] = "https://r2.webampskins.org/skins/\(md5).wsz"
        skins["nodes"] = nodes
        data["skins"] = skins
        json["data"] = data
        return try JSONSerialization.data(withJSONObject: json)
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
