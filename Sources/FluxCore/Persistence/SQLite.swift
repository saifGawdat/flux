import Foundation
import SQLite3

public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func text(_ s: String?) -> SQLiteValue { s.map { .text($0) } ?? .null }
    static func integer(_ i: Int64?) -> SQLiteValue { i.map { .integer($0) } ?? .null }
    static func real(_ d: Double?) -> SQLiteValue { d.map { .real($0) } ?? .null }
    static func bool(_ b: Bool) -> SQLiteValue { .integer(b ? 1 : 0) }
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public struct SQLiteRow: Sendable {
    let values: [String: SQLiteValue]

    func string(_ column: String) -> String? {
        if case .text(let s)? = values[column] { return s }
        return nil
    }

    func int64(_ column: String) -> Int64? {
        switch values[column] {
        case .integer(let i)?: return i
        case .real(let d)?: return Int64(d)
        default: return nil
        }
    }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let d)?: return d
        case .integer(let i)?: return Double(i)
        default: return nil
        }
    }

    func bool(_ column: String) -> Bool { (int64(column) ?? 0) != 0 }
}

/// Minimal synchronous SQLite connection. Not thread-safe on its own: it is owned and
/// serialized by the `FluxDatabase` actor.
final class SQLiteConnection {
    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close_v2(db)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteError(code: rc, message: message)
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: lastErrorMessage) }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let columnCount = sqlite3_column_count(statement)
        let names = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [SQLiteRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: lastErrorMessage) }
            var values: [String: SQLiteValue] = [:]
            for i in 0..<columnCount {
                values[names[Int(i)]] = column(statement, i)
            }
            rows.append(SQLiteRow(values: values))
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func userVersion() throws -> Int {
        Int(try query("PRAGMA user_version").first?.int64("user_version") ?? 0)
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: Private

    private var lastErrorMessage: String { String(cString: sqlite3_errmsg(db)) }

    private func prepare(_ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw SQLiteError(code: rc, message: "\(lastErrorMessage) — in: \(sql)")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch value {
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            case .integer(let v):
                bindResult = sqlite3_bind_int64(statement, index, v)
            case .real(let v):
                bindResult = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                bindResult = sqlite3_bind_text(statement, index, v, -1, transient)
            case .blob(let v):
                bindResult = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard bindResult == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw SQLiteError(code: bindResult, message: lastErrorMessage)
            }
        }
        return statement
    }

    private func column(_ statement: OpaquePointer, _ i: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, i))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, i))
        case SQLITE_TEXT:
            return sqlite3_column_text(statement, i).map { .text(String(cString: $0)) } ?? .null
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, i))
            guard count > 0, let bytes = sqlite3_column_blob(statement, i) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}
