import Foundation
import SQLite3

/// A thin, safe wrapper over the SQLite3 C API.
///
/// All access is serialized through an internal queue; callers never touch
/// handles directly. Prepared statements are cached per SQL string.
/// Errors surface as `SQLiteError` with the underlying message.
public final class SQLiteDatabase: @unchecked Sendable {
    public enum SQLiteError: Error, CustomStringConvertible, Sendable {
        case open(String)
        case prepare(sql: String, message: String)
        case step(sql: String, message: String)
        case bind(sql: String, index: Int, message: String)
        case corrupt

        public var description: String {
            switch self {
            case .open(let path): return "sqlite open failed: \(path)"
            case .prepare(let sql, let message): return "sqlite prepare failed: \(sql) — \(message)"
            case .step(let sql, let message): return "sqlite step failed: \(sql) — \(message)"
            case .bind(let sql, let index, let message): return "sqlite bind failed: \(sql) @\(index) — \(message)"
            case .corrupt: return "sqlite database corrupt"
            }
        }
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "local.ankivoice.sqlite")
    private static let onQueueKey = DispatchSpecificKey<UInt8>()
    private var statements: [String: OpaquePointer] = [:]

    /// Runs `body` on the serialization queue, re-entrantly: calls made while
    /// already on the queue (e.g. inside `transaction`) execute inline instead
    /// of deadlocking on `dispatch_sync`.
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.onQueueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    // MARK: Lifecycle

    public static func open(url: URL, readOnly: Bool = false) throws -> SQLiteDatabase {
        // Read-only opens use the immutable URI flag so WAL sidecar files are
        // never required — the database bytes can live anywhere (e.g. a temp
        // file extracted from an .apkg).
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let path = readOnly ? "file:\(url.path)?immutable=1" : url.path
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close_v2(handle)
            throw SQLiteError.open("\(url.path): \(message)")
        }
        let db = SQLiteDatabase(handle: handle)
        if !readOnly {
            try db.execute("PRAGMA journal_mode=WAL")
            try db.execute("PRAGMA foreign_keys=ON")
            try db.execute("PRAGMA synchronous=NORMAL")
        }
        return db
    }

    /// In-memory database, primarily for tests.
    public static func inMemory() throws -> SQLiteDatabase {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close_v2(handle)
            throw SQLiteError.open(":memory:: \(message)")
        }
        return SQLiteDatabase(handle: handle)
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
        queue.setSpecific(key: Self.onQueueKey, value: 1)
    }

    deinit {
        for stmt in statements.values { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    // MARK: Execution

    /// Runs a statement that returns no rows (DDL, pragmas, writes without bindings).
    public func execute(_ sql: String) throws {
        try onQueue {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &err)
            guard rc == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "rc=\(rc)"
                sqlite3_free(err)
                throw SQLiteError.step(sql: sql, message: message)
            }
            sqlite3_free(err)
        }
    }

    /// Runs a write with positional `?` bindings; returns the last inserted rowid.
    @discardableResult
    public func run(_ sql: String, _ binds: [SQLiteValue] = []) throws -> Int64 {
        try onQueue {
            let stmt = try prepared(sql)
            try bind(binds, to: stmt, sql: sql)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw SQLiteError.step(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return sqlite3_last_insert_rowid(handle)
        }
    }

    /// Runs a write and returns the number of changed rows.
    public func runUpdate(_ sql: String, _ binds: [SQLiteValue] = []) throws -> Int {
        try onQueue {
            let stmt = try prepared(sql)
            try bind(binds, to: stmt, sql: sql)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw SQLiteError.step(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
            }
            let changed = sqlite3_changes64(handle)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return Int(changed)
        }
    }

    /// Queries rows and maps them through `transform`.
    public func query<T>(_ sql: String, _ binds: [SQLiteValue] = [], _ transform: (Row) -> T) throws -> [T] {
        try onQueue {
            let stmt = try prepared(sql)
            try bind(binds, to: stmt, sql: sql)
            defer {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
            }
            var results: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    results.append(transform(Row(stmt: stmt)))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.step(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
                }
            }
            return results
        }
    }

    /// Depth of nested `transaction` calls; only touched on the queue.
    private var transactionDepth = 0

    /// Transaction helper. Rolls back on thrown error.
    ///
    /// Re-entrant: a `transaction` opened while one is already active (the
    /// importer batches notes inside one, and `createNote` opens its own)
    /// becomes a SAVEPOINT, so an inner failure rolls back only its own work
    /// and the outer transaction decides whether to continue. SQLite itself
    /// rejects a nested BEGIN.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try onQueue {
            if transactionDepth > 0 {
                let savepoint = "sp\(transactionDepth)"
                try executeRaw("SAVEPOINT \(savepoint)")
                transactionDepth += 1
                defer { transactionDepth -= 1 }
                do {
                    let value = try body()
                    try executeRaw("RELEASE SAVEPOINT \(savepoint)")
                    return value
                } catch {
                    try? executeRaw("ROLLBACK TO SAVEPOINT \(savepoint)")
                    try? executeRaw("RELEASE SAVEPOINT \(savepoint)")
                    throw error
                }
            }

            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "begin failed"
                sqlite3_free(err)
                throw SQLiteError.step(sql: "BEGIN", message: message)
            }
            sqlite3_free(err)
            transactionDepth = 1
            defer { transactionDepth = 0 }
            do {
                let value = try body()
                try executeRaw("COMMIT")
                return value
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    private func executeRaw(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError.step(sql: sql, message: message)
        }
        sqlite3_free(err)
    }

    // MARK: Statement management

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        let flags = UInt32(bitPattern: SQLITE_PREPARE_PERSISTENT)
        guard sqlite3_prepare_v3(handle, sql, -1, flags, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        statements[sql] = stmt
        return stmt
    }

    /// SQLITE_TRANSIENT destructor: tells SQLite to copy bound values.
    private static let transient = unsafeBitCast(
        UnsafeMutableRawPointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    private func bind(_ values: [SQLiteValue], to stmt: OpaquePointer, sql: String) throws {
        for (index, value) in values.enumerated() {
            let idx = Int32(index + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v): rc = v.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, idx, bytes.baseAddress, Int32(v.count), Self.transient)
            }
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError.bind(sql: sql, index: index + 1, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

// MARK: - Values & rows

public enum SQLiteValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLiteValue {
    public static func bool(_ v: Bool) -> SQLiteValue { .int(v ? 1 : 0) }
    public static func date(_ d: Date) -> SQLiteValue { .double(d.timeIntervalSince1970) }
    public static func optionalDate(_ d: Date?) -> SQLiteValue { d.map { .double($0.timeIntervalSince1970) } ?? .null }
    public static func optionalText(_ s: String?) -> SQLiteValue { s.map { .text($0) } ?? .null }
    public static func optionalInt(_ i: Int?) -> SQLiteValue { i.map { .int(Int64($0)) } ?? .null }
    public static func optionalDouble(_ d: Double?) -> SQLiteValue { d.map { .double($0) } ?? .null }
}

/// Cursor over one result row.
public struct Row {
    fileprivate let stmt: OpaquePointer

    fileprivate init(stmt: OpaquePointer) { self.stmt = stmt }

    public func isNull(_ index: Int) -> Bool {
        sqlite3_column_type(stmt, Int32(index)) == SQLITE_NULL
    }

    public func int(_ index: Int) -> Int64 {
        sqlite3_column_int64(stmt, Int32(index))
    }

    public func intOr(_ index: Int, _ fallback: Int64 = 0) -> Int64 {
        isNull(index) ? fallback : int(index)
    }

    public func int32(_ index: Int) -> Int { Int(int(index)) }

    public func double(_ index: Int) -> Double {
        sqlite3_column_double(stmt, Int32(index))
    }

    public func doubleOrNil(_ index: Int) -> Double? {
        isNull(index) ? nil : double(index)
    }

    public func string(_ index: Int) -> String {
        guard let cString = sqlite3_column_text(stmt, Int32(index)) else { return "" }
        return String(cString: cString)
    }

    public func stringOrNil(_ index: Int) -> String? {
        isNull(index) ? nil : string(index)
    }

    public func date(_ index: Int) -> Date {
        Date(timeIntervalSince1970: double(index))
    }

    public func dateOrNil(_ index: Int) -> Date? {
        isNull(index) ? nil : date(index)
    }

    public func blob(_ index: Int) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, Int32(index)) else { return Data() }
        let count = Int(sqlite3_column_bytes(stmt, Int32(index)))
        return Data(bytes: bytes, count: count)
    }
}
