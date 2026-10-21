import Foundation
import SkinLibrary

/// What the Skins window and menu need from the index. `SkinIndexStore` conforms; tests use an in-memory stub.
public protocol SkinIndexReading: Sendable {
    func counts() async throws -> SkinIndexCounts
    func skins(matching query: SkinQuery) async throws -> [SkinRecord]
    func count(matching query: SkinQuery) async throws -> Int
    func neighbor(of id: Int64, direction: SkinNeighborDirection, statuses: Set<SkinStatus>) async throws -> SkinRecord?
    func skin(atPath path: String) async throws -> SkinRecord?
    func randomSkin(statuses: Set<SkinStatus>) async throws -> SkinRecord?
    /// Skins by MD5, for badging a Skin Museum page (#0126).
    func skins(md5s: [String]) async throws -> [String: SkinRecord]
    /// The skin with this SHA-256, so a Museum download never writes a second copy (#0126).
    func skin(hash: String) async throws -> SkinRecord?
}

extension SkinIndexStore: SkinIndexReading {}
