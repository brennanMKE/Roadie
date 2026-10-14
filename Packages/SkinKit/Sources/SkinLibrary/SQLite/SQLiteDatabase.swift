import Foundation
import SQLite3

/// The `SQLITE_TRANSIENT` destructor (-1): SQLite copies the bytes before the bind call returns.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin wrapper over the system SQLite. Not `Sendable`: one instance lives inside `SkinIndexStore`'s actor.
final class SQLiteDatabase {
    private var db: OpaquePointer?
    private var cache: [String: Statement] = [:]

    init(url: URL) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        db = handle
        guard code == SQLITE_OK else {
            let error = SQLiteDatabase.error(handle, code)
            if let handle { sqlite3_close_v2(handle) }
            db = nil
            throw error
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA temp_store=MEMORY")
        try execute("PRAGMA busy_timeout=5000")
    }

    deinit {
        cache.removeAll()   // finalizes every statement
        if let db { sqlite3_close_v2(db) }
    }

    private static func error(_ db: OpaquePointer?, _ code: Int32) -> SkinLibraryError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(code)"
        return .sqlite(code: code, message: message)
    }

    func clearStatementCache() { cache.removeAll() }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    func lastError(_ code: Int32) -> SkinLibraryError { SQLiteDatabase.error(db, code) }

    func execute(_ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw lastError(code) }
    }

    /// A cached prepared statement, reset and with bindings cleared.
    func statement(_ sql: String) throws -> Statement {
        if let cached = cache[sql] {
            cached.reset()
            return cached
        }
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else { throw lastError(code) }
        let statement = Statement(handle: handle, database: self)
        cache[sql] = statement
        return statement
    }

    /// An uncached statement (dynamic SQL such as `IN (?,?,…)` lists).
    func temporaryStatement(_ sql: String) throws -> Statement {
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else { throw lastError(code) }
        return Statement(handle: handle, database: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    var userVersion: Int32 {
        get {
            guard let statement = try? statement("PRAGMA user_version") else { return 0 }
            // Reset so the cached statement does not hold a read transaction open (it would pin the WAL).
            defer { statement.reset() }
            guard (try? statement.step()) == true else { return 0 }
            return Int32(statement.int64(0))
        }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    /// Runs a single-column text pragma or query and returns every row.
    func strings(_ sql: String) throws -> [String] {
        let statement = try temporaryStatement(sql)
        var rows: [String] = []
        while try statement.step() { rows.append(statement.string(0)) }
        return rows
    }

    final class Statement {
        private var handle: OpaquePointer?
        private unowned let database: SQLiteDatabase

        fileprivate init(handle: OpaquePointer, database: SQLiteDatabase) {
            self.handle = handle
            self.database = database
        }

        deinit { sqlite3_finalize(handle) }

        func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        func bind(_ value: Int64, at index: Int32) throws {
            try check(sqlite3_bind_int64(handle, index, value))
        }

        func bind(_ value: Double, at index: Int32) throws {
            try check(sqlite3_bind_double(handle, index, value))
        }

        func bind(_ value: String, at index: Int32) throws {
            try check(sqlite3_bind_text(handle, index, value, -1, sqliteTransient))
        }

        func bind(_ value: String?, at index: Int32) throws {
            if let value { try bind(value, at: index) } else { try check(sqlite3_bind_null(handle, index)) }
        }

        /// `true` when a row is ready, `false` at the end.
        @discardableResult
        func step() throws -> Bool {
            let code = sqlite3_step(handle)
            switch code {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw database.lastError(code)
            }
        }

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }

        func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(handle, column) else { return "" }
            return String(cString: text)
        }

        func optionalString(_ column: Int32) -> String? {
            isNull(column) ? nil : string(column)
        }

        private func check(_ code: Int32) throws {
            guard code == SQLITE_OK else { throw database.lastError(code) }
        }
    }
}
