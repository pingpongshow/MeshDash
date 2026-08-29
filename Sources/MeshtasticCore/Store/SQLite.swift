import Foundation
import SQLite3

/// SQLITE_TRANSIENT tells SQLite to copy bound strings and blobs, which is what
/// we want since our Swift buffers do not outlive the bind call.
private let sqliteTransient = unsafeBitCast(-1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

public enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the MeshDash database: \(message)"
        case .prepare(let message, let sql): "Database prepare failed: \(message) — \(sql)"
        case .step(let message, let sql): "Database step failed: \(message) — \(sql)"
        }
    }
}

/// Values we can bind to a statement.
public enum SQLValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: UInt32) { self = .integer(Int64(value)) }
    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Data) { self = .blob(value) }
    public init(_ value: Date) { self = .real(value.timeIntervalSince1970) }

    public init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    public init(_ value: UInt32?) { self = value.map { .integer(Int64($0)) } ?? .null }
    public init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
    public init(_ value: Float?) { self = value.map { .real(Double($0)) } ?? .null }
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// A single result row, addressed by column index.
public struct SQLRow {
    fileprivate let statement: OpaquePointer

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    public func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    public func intOptional(_ index: Int32) -> Int64? { isNull(index) ? nil : int(index) }
    public func uint32(_ index: Int32) -> UInt32 { UInt32(truncatingIfNeeded: int(index)) }
    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    public func doubleOptional(_ index: Int32) -> Double? { isNull(index) ? nil : double(index) }
    public func floatOptional(_ index: Int32) -> Float? { isNull(index) ? nil : Float(double(index)) }
    public func bool(_ index: Int32) -> Bool { int(index) != 0 }
    public func date(_ index: Int32) -> Date { Date(timeIntervalSince1970: double(index)) }
    public func dateOptional(_ index: Int32) -> Date? { isNull(index) ? nil : date(index) }

    public func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    public func stringOptional(_ index: Int32) -> String? {
        isNull(index) ? nil : string(index)
    }

    public func data(_ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

/// Minimal synchronous SQLite wrapper. Callers serialize access themselves;
/// `MeshStore` does that by being an actor.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw SQLiteError.open(message)
        }
        // WAL keeps reads fast while a write is in flight, and the busy timeout
        // covers the brief overlap when the app writes from two tasks.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close_v2(handle) }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    /// Runs one or more statements with no bindings and no results.
    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.step(errorMessage, sql: sql)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteError.step(errorMessage, sql: sql)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query<T>(_ sql: String, _ bindings: [SQLValue] = [], read: (SQLRow) -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                results.append(read(SQLRow(statement: statement)))
            } else if status == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.step(errorMessage, sql: sql)
            }
        }
        return results
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        var handleOut: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &handleOut, nil) == SQLITE_OK, let statement = handleOut else {
            sqlite3_finalize(handleOut)
            throw SQLiteError.prepare(errorMessage, sql: sql)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                sqlite3_bind_double(statement, index, number)
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .blob(let data):
                if data.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    _ = data.withUnsafeBytes { raw in
                        sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), sqliteTransient)
                    }
                }
            }
        }
        return statement
    }
}
