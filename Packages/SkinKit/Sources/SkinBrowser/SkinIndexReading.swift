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
}

extension SkinIndexStore: SkinIndexReading {}
