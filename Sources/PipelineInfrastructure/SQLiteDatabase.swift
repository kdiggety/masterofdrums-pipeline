import Foundation
import SQLite3

public struct SQLiteConfiguration: Sendable {
    public let databasePath: String
    public let artifactRoot: String
    public let autoMigrate: Bool

    public init(databasePath: String, artifactRoot: String = "./var/artifacts", autoMigrate: Bool = true) {
        self.databasePath = databasePath
        self.artifactRoot = artifactRoot
        self.autoMigrate = autoMigrate
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SQLiteConfiguration {
        SQLiteConfiguration(
            databasePath: environment["PIPELINE_DATABASE_PATH"] ?? "./var/masterofdrums-pipeline.sqlite",
            artifactRoot: environment["PIPELINE_ARTIFACT_ROOT"] ?? "./var/artifacts",
            autoMigrate: (environment["PIPELINE_AUTO_MIGRATE"] ?? "true").lowercased() == "true"
        )
    }
}

public enum SQLiteDatabaseError: LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message), .executeFailed(let message), .prepareFailed(let message), .stepFailed(let message), .bindFailed(let message):
            return message
        }
    }
}

public struct SQLiteDatabase: Sendable {
    public let configuration: SQLiteConfiguration

    public init(configuration: SQLiteConfiguration) {
        self.configuration = configuration
    }

    public func ensureParentDirectoryExists() throws {
        let url = URL(fileURLWithPath: configuration.databasePath)
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func openDescription() -> String {
        configuration.databasePath
    }

    public func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try ensureParentDirectoryExists()

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(configuration.databasePath, &handle, flags, nil)

        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database"
            if let handle { sqlite3_close(handle) }
            throw SQLiteDatabaseError.openFailed(message)
        }

        defer { sqlite3_close(handle) }
        try execute("PRAGMA foreign_keys = ON;", on: handle)
        return try body(handle)
    }

    public func execute(_ sql: String, on handle: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw SQLiteDatabaseError.executeFailed(message)
        }
    }

    public func prepare(_ sql: String, on handle: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    public func bind(text: String?, at index: Int32, in statement: OpaquePointer, on handle: OpaquePointer) throws {
        let result: Int32
        if let text {
            result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SQLiteDatabaseError.bindFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func bind(int: Int, at index: Int32, in statement: OpaquePointer, on handle: OpaquePointer) throws {
        let result = sqlite3_bind_int64(statement, index, sqlite3_int64(int))
        guard result == SQLITE_OK else {
            throw SQLiteDatabaseError.bindFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func stepExpectDone(_ statement: OpaquePointer, on handle: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SQLiteDatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func iso8601String(from date: Date?) -> String? {
        guard let date else { return nil }
        return Self.iso8601Formatter.string(from: date)
    }

    public func date(from iso8601: String?) -> Date? {
        guard let iso8601 else { return nil }
        return Self.iso8601Formatter.date(from: iso8601)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
