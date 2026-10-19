import Foundation
import SQLite3

public enum DatabaseError: Error, CustomStringConvertible, Equatable {
    case open(String)
    case prepare(String, sql: String)
    case step(String)
    case bind(String)

    public var description: String {
        switch self {
        case let .open(message): "open: \(message)"
        case let .prepare(message, sql): "prepare: \(message) — \(sql.prefix(80))"
        case let .step(message): "step: \(message)"
        case let .bind(message): "bind: \(message)"
        }
    }
}

/// Values bindable to SQLite statements.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    public static func optional(_ value: Double?) -> SQLValue { value.map(SQLValue.real) ?? .null }
    public static func optional(_ value: Int64?) -> SQLValue { value.map(SQLValue.integer) ?? .null }
}

/// A thin, synchronous wrapper around the system SQLite library. `PersistenceController`
/// confines each instance to one serial queue (and the connection is opened in serialized
/// mode), which is why it can be marked `@unchecked Sendable`.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    public let url: URL?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (creating if needed) a database file. `nil` opens an in-memory database.
    public init(url: URL?) throws {
        self.url = url
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let path = url?.path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DatabaseError.open(message)
        }
        if let url { chmod(url.path, 0o600) }
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw DatabaseError.step(message)
        }
    }

    /// Runs a statement with bound parameters and no result rows.
    public func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw DatabaseError.step(errorMessage) }
    }

    /// Runs a query and maps each row.
    public func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Row) throws -> T?) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var results: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                if let value = try map(Row(statement: statement)) { results.append(value) }
            } else if result == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.step(errorMessage)
            }
        }
        return results
    }

    public func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64? {
        try query(sql, values) { $0.int(0) }.first
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public var userVersion: Int {
        get { Int((try? scalarInt("PRAGMA user_version;")) ?? 0) }
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(errorMessage, sql: sql)
        }
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case let .integer(number): result = sqlite3_bind_int64(statement, index, number)
            case let .real(number): result = sqlite3_bind_double(statement, index, number)
            case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, SQLiteDatabase.transient)
            }
            guard result == SQLITE_OK else { throw DatabaseError.bind(errorMessage) }
        }
    }

    public struct Row {
        let statement: OpaquePointer?

        public func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        public func int(_ column: Int32) -> Int64? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, column)
        }

        public func double(_ column: Int32) -> Double? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, column)
        }
    }
}
