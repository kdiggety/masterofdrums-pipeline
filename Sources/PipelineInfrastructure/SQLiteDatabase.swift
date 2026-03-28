import Foundation

public struct SQLiteConfiguration: Sendable {
    public let databasePath: String
    public let autoMigrate: Bool

    public init(databasePath: String, autoMigrate: Bool = true) {
        self.databasePath = databasePath
        self.autoMigrate = autoMigrate
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SQLiteConfiguration {
        SQLiteConfiguration(
            databasePath: environment["PIPELINE_DATABASE_PATH"] ?? "./var/masterofdrums-pipeline.sqlite",
            autoMigrate: (environment["PIPELINE_AUTO_MIGRATE"] ?? "true").lowercased() == "true"
        )
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
}
