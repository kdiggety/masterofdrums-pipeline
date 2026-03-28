import Foundation
import PipelineApplication

public final class SQLiteMigrator: DatabaseMigrator, @unchecked Sendable {
    public let database: SQLiteDatabase
    private let initialSchemaVersion = "001_initial_schema"

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func applyMigrations() async throws {
        try database.withConnection { handle in
            try database.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL);", on: handle)

            let alreadyApplied = try migrationExists(version: initialSchemaVersion, on: handle)
            guard !alreadyApplied else { return }

            try database.execute(Self.initialSchemaSQL, on: handle)

            let statement = try database.prepare(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);",
                on: handle
            )
            defer { sqlite3_finalize(statement) }

            try database.bind(text: initialSchemaVersion, at: 1, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: Date()), at: 2, in: statement, on: handle)
            try database.stepExpectDone(statement, on: handle)
        }
    }

    private func migrationExists(version: String, on handle: OpaquePointer) throws -> Bool {
        let statement = try database.prepare(
            "SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1;",
            on: handle
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(text: version, at: 1, in: statement, on: handle)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw SQLiteDatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
    }

    public static let initialSchemaSQL: String = #"PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS workflows (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL,
    requested_by TEXT,
    idempotency_key TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    last_error TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workflows_idempotency_key
    ON workflows(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_workflows_status_created_at
    ON workflows(status, created_at);

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    type TEXT NOT NULL,
    status TEXT NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL,
    priority INTEGER NOT NULL DEFAULT 100,
    run_after TEXT NOT NULL,
    claimed_at TEXT,
    claimed_by TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    last_error TEXT,
    payload_json TEXT NOT NULL,
    result_json TEXT,
    FOREIGN KEY (workflow_id) REFERENCES workflows(id)
);

CREATE INDEX IF NOT EXISTS idx_jobs_workflow_id
    ON jobs(workflow_id);

CREATE INDEX IF NOT EXISTS idx_jobs_status_run_after_priority
    ON jobs(status, run_after, priority);

CREATE INDEX IF NOT EXISTS idx_jobs_claimed_by
    ON jobs(claimed_by);

CREATE TABLE IF NOT EXISTS workflow_events (
    id TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    job_id TEXT,
    event_type TEXT NOT NULL,
    message TEXT,
    details_json TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (workflow_id) REFERENCES workflows(id),
    FOREIGN KEY (job_id) REFERENCES jobs(id)
);

CREATE INDEX IF NOT EXISTS idx_workflow_events_workflow_id_created_at
    ON workflow_events(workflow_id, created_at);

CREATE INDEX IF NOT EXISTS idx_workflow_events_job_id
    ON workflow_events(job_id);

CREATE TABLE IF NOT EXISTS artifacts (
    id TEXT PRIMARY KEY,
    workflow_id TEXT,
    job_id TEXT,
    artifact_type TEXT NOT NULL,
    uri TEXT NOT NULL,
    content_type TEXT,
    checksum TEXT,
    metadata_json TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (workflow_id) REFERENCES workflows(id),
    FOREIGN KEY (job_id) REFERENCES jobs(id)
);

CREATE INDEX IF NOT EXISTS idx_artifacts_workflow_id
    ON artifacts(workflow_id);

CREATE INDEX IF NOT EXISTS idx_artifacts_job_id
    ON artifacts(job_id);

CREATE INDEX IF NOT EXISTS idx_artifacts_artifact_type
    ON artifacts(artifact_type);

CREATE TABLE IF NOT EXISTS idempotency_keys (
    idempotency_key TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    job_id TEXT,
    request_fingerprint TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (workflow_id) REFERENCES workflows(id),
    FOREIGN KEY (job_id) REFERENCES jobs(id)
);
"#
}
