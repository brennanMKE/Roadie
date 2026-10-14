import Foundation

/// The image proxy keys on `proxy_id`, needs no credentials and accepts only a fixed set of sizes.
public enum MAImageProxy {
    public static let allowedSizes = [80, 160, 256, 512, 1024]

    /// The smallest allowed size that is at least `maxPixels`, else 0 (the original).
    public static func size(for maxPixels: Int) -> Int {
        allowedSizes.first { $0 >= maxPixels } ?? 0
    }

    public static func url(base: URL, proxyID: String, size: Int) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/imageproxy/" + proxyID
        components.queryItems = [URLQueryItem(name: "size", value: String(size))]
        return components.url
    }
}
