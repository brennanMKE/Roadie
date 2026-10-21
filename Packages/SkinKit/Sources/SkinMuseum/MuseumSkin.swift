import Foundation

/// One classic skin row from the Winamp Skin Museum. `id` is the Museum's md5.
public struct MuseumSkin: Identifiable, Hashable, Sendable, Codable {
    public var md5: String
    public var filename: String
    public var screenshotURL: URL
    public var downloadURL: URL
    public var museumURL: URL
    /// nil means never reviewed.
    public var nsfw: Bool?

    public var id: String { md5 }

    public init(md5: String, filename: String, screenshotURL: URL, downloadURL: URL, museumURL: URL, nsfw: Bool?) {
        self.md5 = md5
        self.filename = filename
        self.screenshotURL = screenshotURL
        self.downloadURL = downloadURL
        self.museumURL = museumURL
        self.nsfw = nsfw
    }

    enum CodingKeys: String, CodingKey {
        case md5, filename, nsfw
        case screenshotURL = "screenshot_url"
        case downloadURL = "download_url"
        case museumURL = "museum_url"
    }

    /// The filename without its extension and without the Museum's `_[S123]` suffix.
    public var displayName: String {
        var name = filename
        if let dot = name.lastIndex(of: "."), dot != name.startIndex { name = String(name[..<dot]) }
        if let range = name.range(of: #"_\[S\d+\]$"#, options: .regularExpression) { name.removeSubrange(range) }
        return name
    }

    /// 32 lowercase hex characters, the only form that may become a cache path.
    public static func isValidMD5(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Valid md5 and https URLs for everything fetched or opened.
    var isAcceptable: Bool {
        Self.isValidMD5(md5) && [screenshotURL, downloadURL, museumURL].allSatisfy { $0.scheme?.lowercased() == "https" }
    }
}

/// One page of results. `total` is known for browse only.
public struct MuseumPage: Sendable, Hashable, Codable {
    public var skins: [MuseumSkin]
    public var total: Int?
    public var hasMore: Bool

    public init(skins: [MuseumSkin], total: Int?, hasMore: Bool) {
        self.skins = skins
        self.total = total
        self.hasMore = hasMore
    }
}
