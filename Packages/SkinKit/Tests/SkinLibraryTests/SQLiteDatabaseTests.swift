import Foundation
import SQLite3
import Testing

@testable import SkinLibrary

@Suite struct SQLiteDatabaseTests {
    private func makeDB() throws -> (SQLiteDatabase, TempDir) {
        let dir = try TempDir()
        return (try SQLiteDatabase(url: dir.appending("test.sqlite")), dir)
    }

    @Test func opensWithWALAndForeignKeys() throws {
        let (db, dir) = try makeDB()
        defer { dir.cleanup() }
        #expect(try db.strings("PRAGMA journal_mode") == ["wal"])
        #expect(try db.strings("PRAGMA foreign_keys") == ["1"])
    }

    @Test func fts5IsCompiledIn() throws {
        let (db, dir) = try makeDB()
        defer { dir.cleanup() }
        let options = try db.strings("PRAGMA compile_options")
        #expect(options.contains { $0.contains("ENABLE_FTS5") })
    }

    @Test func transactionRollsBackOnThrow() throws {
        let (db, dir) = try makeDB()
        defer { dir.cleanup() }
        try db.execute("CREATE TABLE t (x INTEGER)")
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.execute("INSERT INTO t VALUES (1)")
                throw Boom()
            }
        }
        #expect(try db.strings("SELECT COUNT(*) FROM t") == ["0"])
        try db.transaction { try db.execute("INSERT INTO t VALUES (2)") }
        #expect(try db.strings("SELECT COUNT(*) FROM t") == ["1"])
    }

    @Test func bindsAndReadsEveryType() throws {
        let (db, dir) = try makeDB()
        defer { dir.cleanup() }
        try db.execute("CREATE TABLE t (i INTEGER, d REAL, s TEXT, n TEXT)")
        let insert = try db.statement("INSERT INTO t VALUES (?, ?, ?, ?)")
        try insert.bind(Int64.max, at: 1)
        try insert.bind(1.5, at: 2)
        try insert.bind("it's a \"quote\"", at: 3)
        try insert.bind(nil as String?, at: 4)
        #expect(try insert.step() == false)
        let select = try db.statement("SELECT i, d, s, n FROM t")
        #expect(try select.step())
        #expect(select.int64(0) == Int64.max)
        #expect(select.double(1) == 1.5)
        #expect(select.string(2) == "it's a \"quote\"")
        #expect(select.optionalString(3) == nil)
        #expect(select.isNull(3))
    }

    @Test func errorsCarryCodeAndMessage() throws {
        let (db, dir) = try makeDB()
        defer { dir.cleanup() }
        do {
            try db.execute("SELEKT nonsense")
            Issue.record("bad SQL should throw")
        } catch SkinLibraryError.sqlite(let code, let message) {
            #expect(code == SQLITE_ERROR)
            #expect(!message.isEmpty)
        }
    }
}
