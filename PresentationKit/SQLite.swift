import Foundation
import SQLite3

/// Minimal SQLite wrapper (system library, no dependencies). Not thread-safe:
/// each BibleStore owns one connection and is used from one queue at a time.
final class SQLiteDB {
    private(set) var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var h: OpaquePointer?
        if sqlite3_open_v2(path, &h, flags | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(h)
            throw PresentationKitError.sqlite(msg)
        }
        handle = h
    }
    deinit { close() }
    func close() { if let h = handle { sqlite3_close(h); handle = nil } }

    var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw PresentationKitError.sqlite(m)
        }
    }

    enum Value { case int(Int), text(String), null }

    final class Statement {
        fileprivate var stmt: OpaquePointer?
        fileprivate init(_ s: OpaquePointer?) { stmt = s }
        deinit { sqlite3_finalize(stmt) }

        func bind(_ values: [Value]) {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, v) in values.enumerated() {
                let idx = Int32(i + 1)
                switch v {
                case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
                case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLiteDB.transient)
                case .null: sqlite3_bind_null(stmt, idx)
                }
            }
        }
        /// Returns true while rows are available.
        func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }
        func run() -> Bool { let r = sqlite3_step(stmt); return r == SQLITE_DONE || r == SQLITE_ROW }
        func int(_ col: Int32) -> Int { Int(sqlite3_column_int64(stmt, col)) }
        func text(_ col: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, col) else { return "" }
            return String(cString: c)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK else { throw PresentationKitError.sqlite(lastError) }
        return Statement(s)
    }

    func query(_ sql: String, _ values: [Value] = [], _ row: (Statement) -> Void) throws {
        let st = try prepare(sql)
        st.bind(values)
        while st.step() { row(st) }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let st = try prepare(sql)
        st.bind(values)
        guard st.run() else { throw PresentationKitError.sqlite(lastError) }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
