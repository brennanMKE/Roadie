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

    /// Whether `string` is a well-formed hash (64 lowercase hex characters); guards cache paths built from it.
    public static func isValid(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
