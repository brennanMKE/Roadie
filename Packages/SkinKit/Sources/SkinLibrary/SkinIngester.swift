import Foundation
import SkinKit

public protocol SkinIngesting: Sendable {
    /// Cheap: reads the file, returns its content hash. I/O errors throw.
    func hash(_ url: URL) throws -> String
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

    public func hash(_ url: URL) throws -> String { try SkinContentHash.hex(of: url) }

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
