import Foundation
import MusicBackendKit
import Observation
import os

/// List-level playlist edits (#0135): create, rename, delete. Each edit changes the Playlists list at once and
/// puts it back when the backend refuses; the refusal's text goes to `message`.
@MainActor @Observable
public final class PlaylistsModel {
    /// The name sheet the Library window shows.
    public enum NameSheet: Hashable, Identifiable, Sendable {
        /// `adding`: items to add to the new playlist once it exists (#0136).
        case create(adding: [MediaID])
        case rename(LibraryPlaylist)

        public var id: String {
            switch self {
            case .create: "create"
            case .rename(let playlist): "rename:" + playlist.id.rawValue
            }
        }

        public var title: String {
            switch self {
            case .create: "New Playlist"
            case .rename: "Rename Playlist"
            }
        }

        public var initialName: String {
            switch self {
            case .create: "New Playlist"
            case .rename(let playlist): playlist.name
            }
        }

        public var confirmTitle: String {
            switch self {
            case .create: "Create"
            case .rename: "Rename"
            }
        }
    }

    public let backend: any MusicBackend
    public let list: PagedList<LibraryPlaylist>
    public var nameSheet: NameSheet?
    /// The playlist the delete confirmation asks about.
    public var pendingDelete: LibraryPlaylist?
    /// The last failure, for the bar under the list.
    public private(set) var message: String?
    /// Playlists the server refused to rename or delete for want of permission, with its message.
    public private(set) var refusals: [MediaID: String] = [:]

    /// The browser whose selection follows the edits.
    @ObservationIgnored weak var browser: LibraryBrowserModel?
    private static let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "Playlists")

    /// Add to Playlist targets, most recent first (#0136); kept in `defaults`.
    public private(set) var recentTargets: [MediaID] = []
    @ObservationIgnored private let defaults: UserDefaults
    public static let recentTargetsKey = "library.playlists.recentTargets"

    public init(backend: any MusicBackend, list: PagedList<LibraryPlaylist>, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.list = list
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recentTargetsKey),
           let ids = try? JSONDecoder().decode([MediaID].self, from: data) {
            recentTargets = ids
        }
    }

    // MARK: Add to Playlist (#0136)

    /// The submenu's entries; `open` (the playlist being viewed) is left out.
    public func addEntries(excluding open: MediaID?) -> [AddToPlaylistMenu.Entry] {
        AddToPlaylistMenu.entries(playlists: list.items, recent: recentTargets, excluding: open)
    }

    /// Adds `items` (tracks and albums) to `playlist` and remembers it as a recent target. Returns the text for
    /// the main window's marquee: what was added, or why it wasn't.
    @discardableResult
    public func add(_ items: [MediaID], to playlist: LibraryPlaylist) async -> String {
        message = nil
        do {
            try await backend.add(items, toPlaylist: playlist.id)
            recordRecent(playlist.id)
            Self.log.info("added \(items.count, privacy: .public) item(s) to a playlist")
            return AddToPlaylistMenu.notice(adding: items, to: playlist)
        } catch {
            fail(error, for: nil)
            return userMessage(for: error)
        }
    }

    /// "New Playlist…" from Add to Playlist: creates it, then adds `items`. The marquee text, nil when nothing was created.
    public func create(named name: String, adding items: [MediaID]) async -> String? {
        guard let created = await create(named: name) else { return message }
        guard !items.isEmpty else { return nil }
        return await add(items, to: created)
    }

    private func recordRecent(_ id: MediaID) {
        recentTargets = AddToPlaylistMenu.recording(id, in: recentTargets)
        if let data = try? JSONEncoder().encode(recentTargets) { defaults.set(data, forKey: Self.recentTargetsKey) }
    }

    public var canEdit: Bool { backend.capabilities.contains(.playlistEditing) }

    public func canRename(_ playlist: LibraryPlaylist) -> Bool {
        canEdit && playlist.editing.contains(.rename) && refusals[playlist.id] == nil
    }

    public func canDelete(_ playlist: LibraryPlaylist) -> Bool {
        canEdit && playlist.editing.contains(.delete) && refusals[playlist.id] == nil
    }

    /// Why Rename/Delete is off for `playlist`, for the help tag.
    public func refusal(for playlist: LibraryPlaylist) -> String? {
        if let refused = refusals[playlist.id] { return refused }
        if playlist.source == .builtIn { return "Built-in playlists can't be renamed or deleted." }
        return nil
    }

    public func dismissMessage() { message = nil }

    public func askToCreate(adding items: [MediaID] = []) {
        guard canEdit else { return }
        nameSheet = .create(adding: items)
    }

    public func askToRename(_ playlist: LibraryPlaylist) {
        guard canRename(playlist) else { return }
        nameSheet = .rename(playlist)
    }

    public func askToDelete(_ playlist: LibraryPlaylist) {
        guard canDelete(playlist) else { return }
        pendingDelete = playlist
    }

    /// Creates the playlist, lists it first and selects it. nil on failure (`message` says why).
    @discardableResult
    public func create(named name: String) async -> LibraryPlaylist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !trimmed.isEmpty else { return nil }
        message = nil
        do {
            let created = try await backend.createPlaylist(named: trimmed)
            if list.phase == .loaded { list.insert(created, at: 0) }
            browser?.select(created)
            Self.log.info("created a playlist")
            return created
        } catch {
            fail(error, for: nil)
            return nil
        }
    }

    /// Renames at once; puts the old name back when the backend refuses.
    @discardableResult
    public func rename(_ playlist: LibraryPlaylist, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRename(playlist), !trimmed.isEmpty else { return false }
        guard trimmed != playlist.name else { return true }
        message = nil
        let original = list.items.first { $0.id == playlist.id } ?? playlist
        var renamed = original
        renamed.name = trimmed
        apply(renamed)
        do {
            try await backend.renamePlaylist(playlist.id, to: trimmed)
            return true
        } catch {
            apply(original)
            fail(error, for: playlist.id)
            return false
        }
    }

    /// Removes at once (and the selection, when it was this playlist); puts it back when the backend refuses.
    @discardableResult
    public func delete(_ playlist: LibraryPlaylist) async -> Bool {
        guard canDelete(playlist) else { return false }
        message = nil
        let wasSelected = browser?.selectedPlaylist?.id == playlist.id
        let removed = list.remove(id: playlist.id)
        if wasSelected { browser?.selectedPlaylist = nil }
        do {
            try await backend.deletePlaylist(playlist.id)
            return true
        } catch {
            if let removed { list.insert(removed.item, at: removed.index) }
            if wasSelected, let browser, browser.selectedPlaylist == nil, browser.section == .playlists {
                browser.selectedPlaylist = removed?.item ?? playlist
            }
            fail(error, for: playlist.id)
            return false
        }
    }

    // MARK: M3U (#0148)

    /// Export needs the server's library row; import makes a new playlist, so it needs editing.
    public func canExport(_ playlist: LibraryPlaylist) -> Bool { canEdit && playlist.libraryID != nil }

    /// The playlist as M3U8 text, nil on failure (`message` says why).
    public func exportM3U(_ playlist: LibraryPlaylist) async -> String? {
        guard canExport(playlist) else { return nil }
        message = nil
        do {
            let text = try await backend.exportPlaylist(playlist.id)
            Self.log.info("exported a playlist")
            return text
        } catch {
            fail(error, for: nil)
            return nil
        }
    }

    /// Imports M3U8 text as a new playlist, lists it first and selects it. nil on failure (`message` says why).
    @discardableResult
    public func importM3U(_ text: String) async -> LibraryPlaylist? {
        guard canEdit else { return nil }
        message = nil
        do {
            let created = try await backend.importPlaylist(m3u: text)
            if list.phase == .loaded { list.insert(created, at: 0) }
            browser?.select(created)
            Self.log.info("imported a playlist")
            return created
        } catch {
            fail(error, for: nil)
            return nil
        }
    }

    private func apply(_ playlist: LibraryPlaylist) {
        list.replace(playlist)
        if let browser, browser.selectedPlaylist?.id == playlist.id { browser.selectedPlaylist = playlist }
    }

    private func fail(_ error: any Error, for id: MediaID?) {
        if let id, case .forbidden(let text)? = error as? MusicBackendError {
            refusals[id] = text
        }
        message = userMessage(for: error)
        Self.log.info("playlist edit failed")
    }
}
