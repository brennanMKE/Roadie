import CryptoKit
import Foundation

/// The content hash of a skin file: lowercase hex SHA-256 of the whole `.wsz`. The index stores it
/// (`SkinRecord.hash`) and the thumbnail cache (#0034) names its files by it, so there is one function.
public enum SkinContentHash {
    public static func hex(of url: URL) throws -> String {
        hex(of: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 and MD5 of the file from one read. The Skin Museum (#0126) keys skins by MD5.
    public static func digests(of url: URL) throws -> SkinDigests {
        digests(of: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func digests(of data: Data) -> SkinDigests {
        SkinDigests(
            sha256: hex(of: data), md5: Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// Whether `string` is a well-formed MD5 (32 lowercase hex characters).
    public static func isValidMD5(_ string: String) -> Bool {
        string.utf8.count == 32 && string.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// Whether `string` is a well-formed hash (64 lowercase hex characters); guards cache paths built from it.
    public static func isValid(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}

/// Both digests of one skin file, lowercase hex.
public struct SkinDigests: Hashable, Sendable {
    public var sha256: String
    public var md5: String

    public init(sha256: String, md5: String) {
        self.sha256 = sha256
        self.md5 = md5
    }
}
