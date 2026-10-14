import Foundation

extension MusicBackend {
    /// Every page of `albums(of:)` for one id, in order; stops at the last page, an empty page, or `limit` items.
    public func allAlbums(of artist: MediaID, pageSize: Int = 200, limit: Int = 10_000) async throws -> [LibraryAlbum] {
        var result: [LibraryAlbum] = []
        var request = PageRequest(offset: 0, limit: max(1, pageSize))
        while result.count < limit {
            let page = try await albums(of: artist, page: request)
            result.append(contentsOf: page.items)
            guard !page.items.isEmpty, let next = page.next(limit: request.limit) else { break }
            request = next
        }
        return Array(result.prefix(limit))
    }

    /// All members' albums, concatenated in member order, duplicate album ids dropped.
    /// One failing member fails the call.
    public func albums(of group: ArtistGroup, pageSize: Int = 200) async throws -> [LibraryAlbum] {
        let ids = group.memberIDs
        let perMember = try await withThrowingTaskGroup(of: (Int, [LibraryAlbum]).self) { tasks in
            for (index, id) in ids.enumerated() {
                tasks.addTask { (index, try await self.allAlbums(of: id, pageSize: pageSize)) }
            }
            var collected: [(Int, [LibraryAlbum])] = []
            for try await entry in tasks { collected.append(entry) }
            return collected
        }
        var seen: Set<MediaID> = []
        var result: [LibraryAlbum] = []
        for (_, albums) in perMember.sorted(by: { $0.0 < $1.0 }) {
            for album in albums where seen.insert(album.id).inserted { result.append(album) }
        }
        return result
    }
}
