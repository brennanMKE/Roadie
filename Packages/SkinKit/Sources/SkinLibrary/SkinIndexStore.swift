import Foundation

/// What the indexer hands the store per file. Internal: callers go through `SkinIndexer`.
enum IngestOutcome: Sendable {
    case parsed(
        stamp: FileStamp, hash: String, name: String, readme: String?, status: SkinStatus, warnings: [String],
        parserVersion: Int)
    case linked(stamp: FileStamp, hash: String)

    var stamp: FileStamp {
        switch self {
        case .parsed(let stamp, _, _, _, _, _, _), .linked(let stamp, _): stamp
        }
    }
}

struct AppliedCounts: Sendable, Equatable {
    /// New file, new skin.
    var added = 0
    /// A file that was already indexed and has been ingested again.
    var updated = 0
    /// New file whose skin was already known.
    var linked = 0
}

/// The SQLite index: skins, the files that hold them, and an FTS5 table over name and readme.
/// One connection, owned by this actor; every reader and writer goes through it.
public actor SkinIndexStore {
    public static let schemaVersion: Int32 = 1

    /// `~/Library/Application Support/com.brennanmke.SkinAmp/SkinLibrary/index.sqlite`; not Caches, because
    /// an index of 100k skins is minutes of work and must not be purged by the system.
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "com.brennanmke.SkinAmp", directoryHint: .isDirectory)
            .appending(path: "SkinLibrary", directoryHint: .isDirectory)
            .appending(path: "index.sqlite", directoryHint: .notDirectory)
    }

    public nonisolated let url: URL
    private let db: SQLiteDatabase

    public static func open(at url: URL) async throws -> SkinIndexStore {
        try SkinIndexStore(url: url)
    }

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(url: url)
        try SkinIndexStore.migrate(db)
    }

    // MARK: Schema

    private static let schemaV1: [String] = [
        """
        CREATE TABLE skins (
          id INTEGER PRIMARY KEY,
          hash TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          readme TEXT,
          status TEXT NOT NULL,
          warnings TEXT NOT NULL DEFAULT '',
          size INTEGER NOT NULL,
          parser_version INTEGER NOT NULL,
          first_indexed REAL NOT NULL
        )
        """,
        """
        CREATE TABLE files (
          path TEXT PRIMARY KEY,
          size INTEGER NOT NULL,
          mtime REAL NOT NULL,
          skin_id INTEGER NOT NULL REFERENCES skins(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX files_skin ON files(skin_id)",
        "CREATE INDEX skins_status ON skins(status)",
        "CREATE INDEX skins_name ON skins(name COLLATE NOCASE)",
        "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        """
        CREATE VIRTUAL TABLE skins_fts USING fts5(name, readme, content='skins', content_rowid='id', \
        tokenize='unicode61 remove_diacritics 2')
        """,
        """
        CREATE TRIGGER skins_ai AFTER INSERT ON skins BEGIN \
        INSERT INTO skins_fts(rowid, name, readme) VALUES (new.id, new.name, new.readme); END
        """,
        """
        CREATE TRIGGER skins_ad AFTER DELETE ON skins BEGIN \
        INSERT INTO skins_fts(skins_fts, rowid, name, readme) VALUES ('delete', old.id, old.name, old.readme); END
        """,
        """
        CREATE TRIGGER skins_au AFTER UPDATE OF name, readme ON skins BEGIN \
        INSERT INTO skins_fts(skins_fts, rowid, name, readme) VALUES ('delete', old.id, old.name, old.readme); \
        INSERT INTO skins_fts(rowid, name, readme) VALUES (new.id, new.name, new.readme); END
        """,
    ]

    /// Version N is applied by running `migrations[N]`; a database above `schemaVersion` is refused.
    private static let migrations: [Int32: [String]] = [1: schemaV1]

    private static func migrate(_ db: SQLiteDatabase) throws {
        let found = db.userVersion
        guard found <= schemaVersion else {
            throw SkinLibraryError.incompatibleDatabase(found: found, supported: schemaVersion)
        }
        guard found < schemaVersion else { return }
        try db.transaction {
            for version in (found + 1)...schemaVersion {
                for sql in migrations[version] ?? [] { try db.execute(sql) }
            }
            try db.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    // MARK: Pass bookkeeping

    /// The whole `files` table with each file's skin's parser version; 100k rows is a few MB.
    func fileStamps() throws -> [String: (stamp: FileStamp, parserVersion: Int)] {
        let st = try db.statement(
            "SELECT f.path, f.size, f.mtime, s.parser_version FROM files f JOIN skins s ON s.id = f.skin_id")
        defer { st.reset() }
        var result: [String: (stamp: FileStamp, parserVersion: Int)] = [:]
        while try st.step() {
            let path = st.string(0)
            result[path] = (FileStamp(path: path, size: st.int64(1), mtime: st.double(2)), Int(st.int64(3)))
        }
        return result
    }

    /// Skin ids for the hashes already indexed at `parserVersion` or newer (older ones must be parsed again).
    func knownSkinIDs(forHashes hashes: [String], parserVersion: Int) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for start in stride(from: 0, to: hashes.count, by: 500) {
            let chunk = Array(hashes[start..<min(start + 500, hashes.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let st = try db.temporaryStatement(
                "SELECT hash, id FROM skins WHERE parser_version >= ? AND hash IN (\(marks))")
            try st.bind(Int64(parserVersion), at: 1)
            for (index, hash) in chunk.enumerated() { try st.bind(hash, at: Int32(index + 2)) }
            while try st.step() { result[st.string(0)] = st.int64(1) }
        }
        return result
    }

    /// Skin ids for any indexed hash, whatever its parser version.
    public func skinIDs(forHashes hashes: [String]) throws -> [String: Int64] {
        try knownSkinIDs(forHashes: hashes, parserVersion: 0)
    }

    /// Applies one batch in one transaction, in path order so the first path names the skin.
    func apply(_ batch: [IngestOutcome]) throws -> AppliedCounts {
        let ordered = batch.sorted { $0.stamp.path < $1.stamp.path }
        var counts = AppliedCounts()
        let now = Date().timeIntervalSince1970
        try db.transaction {
            let findSkin = try db.statement("SELECT id FROM skins WHERE hash = ?")
            let findFile = try db.statement("SELECT 1 FROM files WHERE path = ?")
            let insertSkin = try db.statement(
                """
                INSERT INTO skins(hash, name, readme, status, warnings, size, parser_version, first_indexed) \
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let updateSkin = try db.statement(
                "UPDATE skins SET status = ?, warnings = ?, readme = ?, parser_version = ? WHERE id = ?")
            let putFile = try db.statement(
                "INSERT OR REPLACE INTO files(path, size, mtime, skin_id) VALUES (?, ?, ?, ?)")
            defer { findSkin.reset(); findFile.reset() }

            for outcome in ordered {
                let stamp = outcome.stamp
                let hash: String
                switch outcome {
                case .parsed(_, let h, _, _, _, _, _), .linked(_, let h): hash = h
                }
                try findFile.bind(stamp.path, at: 1)
                let pathExisted = try findFile.step()
                findFile.reset()

                try findSkin.bind(hash, at: 1)
                var skinID: Int64? = try findSkin.step() ? findSkin.int64(0) : nil
                findSkin.reset()
                var created = false

                switch outcome {
                case .parsed(_, _, let name, let readme, let status, let warnings, let version):
                    if let id = skinID {
                        try updateSkin.bind(status.rawValue, at: 1)
                        try updateSkin.bind(warnings.joined(separator: "\n"), at: 2)
                        try updateSkin.bind(readme, at: 3)
                        try updateSkin.bind(Int64(version), at: 4)
                        try updateSkin.bind(id, at: 5)
                        try updateSkin.step()
                        updateSkin.reset()
                    } else {
                        try insertSkin.bind(hash, at: 1)
                        try insertSkin.bind(name, at: 2)
                        try insertSkin.bind(readme, at: 3)
                        try insertSkin.bind(status.rawValue, at: 4)
                        try insertSkin.bind(warnings.joined(separator: "\n"), at: 5)
                        try insertSkin.bind(stamp.size, at: 6)
                        try insertSkin.bind(Int64(version), at: 7)
                        try insertSkin.bind(now, at: 8)
                        try insertSkin.step()
                        insertSkin.reset()
                        skinID = sqliteLastInsertRowID()
                        created = true
                    }
                case .linked:
                    guard skinID != nil else {
                        throw SkinLibraryError.sqlite(code: 0, message: "linked a file to an unknown skin")
                    }
                }

                guard let id = skinID else { continue }
                try putFile.bind(stamp.path, at: 1)
                try putFile.bind(stamp.size, at: 2)
                try putFile.bind(stamp.mtime, at: 3)
                try putFile.bind(id, at: 4)
                try putFile.step()
                putFile.reset()

                if pathExisted { counts.updated += 1 } else if created { counts.added += 1 } else { counts.linked += 1 }
            }
        }
        return counts
    }

    func removeFiles(_ paths: [String]) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        return try db.transaction {
            let st = try db.statement("DELETE FROM files WHERE path = ?")
            var removed = 0
            for path in paths {
                try st.bind(path, at: 1)
                try st.step()
                st.reset()
                removed += 1
            }
            return removed
        }
    }

    /// Deletes skins no file points at any more (the trigger keeps the FTS table in step).
    @discardableResult
    func pruneOrphans() throws -> Int {
        try db.execute("DELETE FROM skins WHERE id NOT IN (SELECT skin_id FROM files)")
        return Int(try scalar("SELECT changes()") ?? 0)
    }

    func checkpoint() {
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: Reads

    public func counts() throws -> SkinIndexCounts {
        let files = Int(try scalar("SELECT COUNT(*) FROM files") ?? 0)
        var byStatus: [SkinStatus: Int] = [:]
        for status in SkinStatus.allCases { byStatus[status] = 0 }
        let st = try db.statement("SELECT status, COUNT(*) FROM skins GROUP BY status")
        defer { st.reset() }
        var skins = 0
        while try st.step() {
            let n = Int(st.int64(1))
            skins += n
            if let status = SkinStatus(rawValue: st.string(0)) { byStatus[status] = n }
        }
        return SkinIndexCounts(files: files, skins: skins, byStatus: byStatus)
    }

    private static let select = """
        SELECT s.id, s.hash, s.name, s.readme, s.status, s.warnings, s.size, \
        (SELECT COUNT(*) FROM files WHERE skin_id = s.id), \
        COALESCE((SELECT MIN(path) FROM files WHERE skin_id = s.id), '') \
        FROM skins s
        """

    private func record(_ st: SQLiteDatabase.Statement) -> SkinRecord {
        let warnings = st.string(5)
        return SkinRecord(
            id: st.int64(0), hash: st.string(1), name: st.string(2), readme: st.optionalString(3),
            status: SkinStatus(rawValue: st.string(4)) ?? .failed,
            warnings: warnings.isEmpty ? [] : warnings.components(separatedBy: "\n"),
            size: st.int64(6), fileCount: Int(st.int64(7)), primaryPath: st.string(8))
    }

    /// A page ordered by name (case-insensitive), then id.
    public func skins(status: SkinStatus? = nil, limit: Int = 200, offset: Int = 0) throws -> [SkinRecord] {
        let st = try db.statement(
            Self.select + " WHERE (?1 IS NULL OR s.status = ?1) ORDER BY s.name COLLATE NOCASE, s.id LIMIT ?2 OFFSET ?3")
        defer { st.reset() }
        try st.bind(status?.rawValue, at: 1)
        try st.bind(Int64(limit), at: 2)
        try st.bind(Int64(offset), at: 3)
        var rows: [SkinRecord] = []
        while try st.step() { rows.append(record(st)) }
        return rows
    }

    /// Full-text search over name and readme: every word is a quoted prefix token, so punctuation cannot
    /// make FTS5 throw. Ordered by relevance.
    public func search(_ text: String, status: SkinStatus? = nil, limit: Int = 200) throws -> [SkinRecord] {
        guard let expression = Self.matchExpression(text) else { return [] }
        let st = try db.statement(
            Self.select
                + " JOIN skins_fts ON skins_fts.rowid = s.id WHERE skins_fts MATCH ?1 AND (?2 IS NULL OR s.status = ?2)"
                + " ORDER BY bm25(skins_fts), s.name COLLATE NOCASE, s.id LIMIT ?3")
        defer { st.reset() }
        try st.bind(expression, at: 1)
        try st.bind(status?.rawValue, at: 2)
        try st.bind(Int64(limit), at: 3)
        var rows: [SkinRecord] = []
        while try st.step() { rows.append(record(st)) }
        return rows
    }

    nonisolated static func matchExpression(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).filter { word in
            word.contains { $0.isLetter || $0.isNumber }
        }
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " ")
    }

    public func skin(id: Int64) throws -> SkinRecord? {
        let st = try db.statement(Self.select + " WHERE s.id = ?")
        defer { st.reset() }
        try st.bind(id, at: 1)
        return try st.step() ? record(st) : nil
    }

    public func skin(hash: String) throws -> SkinRecord? {
        let st = try db.statement(Self.select + " WHERE s.hash = ?")
        defer { st.reset() }
        try st.bind(hash, at: 1)
        return try st.step() ? record(st) : nil
    }

    public func files(forSkin id: Int64) throws -> [FileStamp] {
        let st = try db.statement("SELECT path, size, mtime FROM files WHERE skin_id = ? ORDER BY path")
        defer { st.reset() }
        try st.bind(id, at: 1)
        var rows: [FileStamp] = []
        while try st.step() { rows.append(FileStamp(path: st.string(0), size: st.int64(1), mtime: st.double(2))) }
        return rows
    }

    public func randomSkin(status: SkinStatus? = nil) throws -> SkinRecord? {
        let st = try db.statement("SELECT id FROM skins WHERE (?1 IS NULL OR status = ?1) ORDER BY random() LIMIT 1")
        defer { st.reset() }
        try st.bind(status?.rawValue, at: 1)
        guard try st.step() else { return nil }
        return try skin(id: st.int64(0))
    }

    // MARK: Browser queries (#0035)

    /// More FTS matches than this are "broad": ranking them all by bm25 before `LIMIT` is the slow part, so they are
    /// listed by name instead (the user types more letters to narrow them).
    static let broadMatchThreshold = 2_000

    private static func placeholders(_ statuses: Set<SkinStatus>) -> String {
        Array(repeating: "?", count: statuses.count).joined(separator: ",")
    }

    private func bindStatuses(_ st: SQLiteDatabase.Statement, _ statuses: Set<SkinStatus>, from first: Int32) throws {
        for (offset, status) in statuses.map(\.rawValue).sorted().enumerated() {
            try st.bind(status, at: first + Int32(offset))
        }
    }

    private func isBroad(_ expression: String) throws -> Bool {
        let st = try db.statement(
            "SELECT COUNT(*) FROM (SELECT 1 FROM skins_fts WHERE skins_fts MATCH ? LIMIT \(Self.broadMatchThreshold + 1))")
        defer { st.reset() }
        try st.bind(expression, at: 1)
        return try st.step() && st.int64(0) > Int64(Self.broadMatchThreshold)
    }

    /// Text + status + page in one SELECT. Text ranks by bm25 then name; a broad match lists by name.
    public func skins(matching query: SkinQuery) throws -> [SkinRecord] {
        guard !query.statuses.isEmpty, query.limit > 0 else { return [] }
        let marks = Self.placeholders(query.statuses)
        let allStatuses = query.statuses.count == SkinStatus.allCases.count
        let sql: String
        let expression: String?
        if query.hasText {
            guard let built = Self.matchExpression(query.text) else { return [] }
            expression = built
            if try isBroad(built) {
                sql = Self.select
                    + " WHERE s.id IN (SELECT rowid FROM skins_fts WHERE skins_fts MATCH ?) AND s.status IN (\(marks))"
                    + " ORDER BY s.name COLLATE NOCASE, s.id LIMIT ? OFFSET ?"
            } else {
                sql = Self.select
                    + " JOIN skins_fts ON skins_fts.rowid = s.id WHERE skins_fts MATCH ? AND s.status IN (\(marks))"
                    + " ORDER BY bm25(skins_fts), s.name COLLATE NOCASE, s.id LIMIT ? OFFSET ?"
            }
        } else {
            expression = nil
            // Walk the name index in order: left to the planner, a status filter picks the status index and sorts
            // all 100k rows. Every status selected needs no filter at all.
            let filter = allStatuses ? "" : " WHERE s.status IN (\(marks))"
            sql = Self.select.replacingOccurrences(of: "FROM skins s", with: "FROM skins s INDEXED BY skins_name")
                + filter + " ORDER BY s.name COLLATE NOCASE, s.id LIMIT ? OFFSET ?"
        }
        let st = try db.temporaryStatement(sql)
        var index: Int32 = 1
        if let expression {
            try st.bind(expression, at: 1)
            index = 2
        }
        let bound = (query.hasText || !allStatuses) ? query.statuses : []
        try bindStatuses(st, bound, from: index)
        try st.bind(Int64(query.limit), at: index + Int32(bound.count))
        try st.bind(Int64(max(0, query.offset)), at: index + Int32(bound.count) + 1)
        var rows: [SkinRecord] = []
        while try st.step() { rows.append(record(st)) }
        return rows
    }

    /// How many rows `skins(matching:)` pages over (ignores limit and offset).
    public func count(matching query: SkinQuery) throws -> Int {
        guard !query.statuses.isEmpty else { return 0 }
        let marks = Self.placeholders(query.statuses)
        var expression: String?
        let sql: String
        if query.hasText {
            guard let built = Self.matchExpression(query.text) else { return 0 }
            expression = built
            // Every status selected: the FTS table alone answers (no join per match).
            sql = query.statuses.count == SkinStatus.allCases.count
                ? "SELECT COUNT(*) FROM skins_fts WHERE skins_fts MATCH ?"
                : "SELECT COUNT(*) FROM skins s JOIN skins_fts ON skins_fts.rowid = s.id"
                + " WHERE skins_fts MATCH ? AND s.status IN (\(marks))"
        } else if query.statuses.count == SkinStatus.allCases.count {
            sql = "SELECT COUNT(*) FROM skins"
        } else {
            sql = "SELECT COUNT(*) FROM skins s WHERE s.status IN (\(marks))"
        }
        let st = try db.temporaryStatement(sql)
        var index: Int32 = 1
        if let expression {
            try st.bind(expression, at: 1)
            index = 2
        }
        if query.statuses.count != SkinStatus.allCases.count {
            try bindStatuses(st, query.statuses, from: index)
        }
        return try st.step() ? Int(st.int64(0)) : 0
    }

    /// The row after/before `id` in (name COLLATE NOCASE, id) order among `statuses`, wrapping around; nil when
    /// no row has one of `statuses`. An id that is no longer in the index behaves as "unknown": first/last row.
    public func neighbor(
        of id: Int64, direction: SkinNeighborDirection, statuses: Set<SkinStatus>
    ) throws -> SkinRecord? {
        guard !statuses.isEmpty else { return nil }
        let marks = Self.placeholders(statuses)
        let count = Int32(statuses.count)
        let forward = direction == .next
        let order = forward ? "ASC" : "DESC"
        let edge = "ORDER BY s.name COLLATE NOCASE \(order), s.id \(order) LIMIT 1"
        if let current = try skin(id: id) {
            let cmp = forward ? ">" : "<"
            let st = try db.temporaryStatement(
                Self.select + " WHERE s.status IN (\(marks)) AND (s.name \(cmp) ? COLLATE NOCASE"
                    + " OR (s.name = ? COLLATE NOCASE AND s.id \(cmp) ?)) " + edge)
            try bindStatuses(st, statuses, from: 1)
            try st.bind(current.name, at: count + 1)
            try st.bind(current.name, at: count + 2)
            try st.bind(current.id, at: count + 3)
            if try st.step() { return record(st) }
        }
        let wrap = try db.temporaryStatement(Self.select + " WHERE s.status IN (\(marks)) " + edge)
        try bindStatuses(wrap, statuses, from: 1)
        return try wrap.step() ? record(wrap) : nil
    }

    /// The skin one of whose files is at this folder-relative path.
    public func skin(atPath path: String) throws -> SkinRecord? {
        let st = try db.statement("SELECT skin_id FROM files WHERE path = ?")
        defer { st.reset() }
        try st.bind(path, at: 1)
        guard try st.step() else { return nil }
        return try skin(id: st.int64(0))
    }

    /// A random row among `statuses`; nil when none.
    public func randomSkin(statuses: Set<SkinStatus>) throws -> SkinRecord? {
        guard !statuses.isEmpty else { return nil }
        let st = try db.temporaryStatement(
            "SELECT id FROM skins WHERE status IN (\(Self.placeholders(statuses))) ORDER BY random() LIMIT 1")
        try bindStatuses(st, statuses, from: 1)
        guard try st.step() else { return nil }
        return try skin(id: st.int64(0))
    }

    // MARK: Meta and reset

    public func meta(_ key: String) throws -> String? {
        let st = try db.statement("SELECT value FROM meta WHERE key = ?")
        defer { st.reset() }
        try st.bind(key, at: 1)
        return try st.step() ? st.string(0) : nil
    }

    public func setMeta(_ key: String, _ value: String) throws {
        let st = try db.statement("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)")
        defer { st.reset() }
        try st.bind(key, at: 1)
        try st.bind(value, at: 2)
        try st.step()
    }

    /// Drops every table and builds the schema again (Settings › Reset Index).
    public func reset() throws {
        db.clearStatementCache()
        try db.transaction {
            for table in ["skins_fts", "files", "skins", "meta"] { try db.execute("DROP TABLE IF EXISTS \(table)") }
            try db.execute("PRAGMA user_version = 0")
        }
        try Self.migrate(db)
    }

    // MARK: Test and diagnostic hooks

    /// Runs a query that returns a single text column (pragmas, diagnostics).
    func strings(_ sql: String) throws -> [String] { try db.strings(sql) }

    func setUserVersion(_ version: Int32) { db.userVersion = version }

    private func scalar(_ sql: String) throws -> Int64? {
        let st = try db.statement(sql)
        defer { st.reset() }
        return try st.step() ? st.int64(0) : nil
    }

    private func sqliteLastInsertRowID() -> Int64 { db.lastInsertRowID }
}
