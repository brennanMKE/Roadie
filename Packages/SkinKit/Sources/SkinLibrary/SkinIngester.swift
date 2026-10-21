import Foundation
import SkinKit

public protocol SkinIngesting: Sendable {
    /// Cheap: reads the file once, returns its SHA-256 (the content hash) and MD5. I/O errors throw.
    func digests(_ url: URL) throws -> SkinDigests
    /// Expensive: parses the archive. Never throws; a rejected skin is a `.failed` inspection.
    func inspect(_ url: URL) -> SkinInspection
}

public struct SkinInspection: Hashable, Sendable {
    public var readme: String?
    public var status: SkinStatus
    public var warnings: [String]

    public init(readme: String?, status: SkinStatus, warnings: [String]) {
        self.readme = readme
        self.status = status
        self.warnings = warnings
    }
}

public struct SkinIngester: SkinIngesting {
    /// Bump when `SkinParser`'s output changes; every file is then re-parsed once.
    public static let parserVersion = 1

    public init() {}

    public func digests(_ url: URL) throws -> SkinDigests { try SkinContentHash.digests(of: url) }

    public func inspect(_ url: URL) -> SkinInspection {
        let archive: SkinArchive
        do {
            archive = try SkinArchive(url: url)
        } catch {
            return SkinInspection(readme: nil, status: .failed, warnings: [error.description])
        }
        let readme = SkinReadme.extract(from: archive)
        do {
            let skin = try SkinParser.parse(archive: archive)
            // Only the warnings survive; the decoded sheets are dropped here.
            return SkinInspection(
                readme: readme, status: skin.warnings.isEmpty ? .ok : .partial, warnings: skin.warnings)
        } catch {
            return SkinInspection(readme: readme, status: .failed, warnings: [error.description])
        }
    }
}
