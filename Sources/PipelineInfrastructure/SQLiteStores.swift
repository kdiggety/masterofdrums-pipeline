import Foundation
import SQLite3
import PipelineApplication
import PipelineDomain

public actor SQLiteWorkflowStore: WorkflowStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func insert(_ workflow: PipelineWorkflow) async throws {
        try database.withConnection { handle in
            let statement = try database.prepare(
                """
                INSERT INTO workflows (
                    id, name, status, requested_by, idempotency_key,
                    created_at, updated_at, started_at, completed_at, last_error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                on: handle
            )
            defer { sqlite3_finalize(statement) }

            try database.bind(text: workflow.id, at: 1, in: statement, on: handle)
            try database.bind(text: workflow.name, at: 2, in: statement, on: handle)
            try database.bind(text: workflow.status.rawValue, at: 3, in: statement, on: handle)
            try database.bind(text: workflow.requestedBy, at: 4, in: statement, on: handle)
            try database.bind(text: workflow.idempotencyKey, at: 5, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: workflow.createdAt), at: 6, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: workflow.updatedAt), at: 7, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: workflow.startedAt), at: 8, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: workflow.completedAt), at: 9, in: statement, on: handle)
            try database.bind(text: workflow.lastError, at: 10, in: statement, on: handle)
            try database.stepExpectDone(statement, on: handle)
        }
    }

    public func markRunning(id: String, startedAt: Date) async throws {
        try database.withConnection { handle in
            let statement = try database.prepare(
                """
                UPDATE workflows
                SET status = ?, started_at = COALESCE(started_at, ?), updated_at = ?, last_error = NULL
                WHERE id = ?;
                """,
                on: handle
            )
            defer { sqlite3_finalize(statement) }

            let startedAtText = database.iso8601String(from: startedAt)
            try database.bind(text: PipelineWorkflowStatus.running.rawValue, at: 1, in: statement, on: handle)
            try database.bind(text: startedAtText, at: 2, in: statement, on: handle)
            try database.bind(text: startedAtText, at: 3, in: statement, on: handle)
            try database.bind(text: id, at: 4, in: statement, on: handle)
            try database.stepExpectDone(statement, on: handle)
        }
    }

    public func markFinished(id: String, status: PipelineWorkflowStatus, completedAt: Date, lastError: String?) async throws {
        try database.withConnection { handle in
            let statement = try database.prepare(
                """
                UPDATE workflows
                SET status = ?, completed_at = ?, updated_at = ?, last_error = ?
                WHERE id = ?;
                """,
                on: handle
            )
            defer { sqlite3_finalize(statement) }

            let completedAtText = database.iso8601String(from: completedAt)
            try database.bind(text: status.rawValue, at: 1, in: statement, on: handle)
            try database.bind(text: completedAtText, at: 2, in: statement, on: handle)
            try database.bind(text: completedAtText, at: 3, in: statement, on: handle)
            try database.bind(text: lastError, at: 4, in: statement, on: handle)
            try database.bind(text: id, at: 5, in: statement, on: handle)
            try database.stepExpectDone(statement, on: handle)
        }
    }
}

public actor SQLiteJobStore: JobStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func enqueue(_ job: PipelineJob) async throws {
        try database.withConnection { handle in
            let statement = try database.prepare(
                """
                INSERT INTO jobs (
                    id, workflow_id, type, status, attempt, max_attempts, priority,
                    run_after, claimed_at, claimed_by, created_at, updated_at,
                    started_at, completed_at, last_error, payload_json, result_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                on: handle
            )
            defer { sqlite3_finalize(statement) }

            try database.bind(text: job.id, at: 1, in: statement, on: handle)
            try database.bind(text: job.workflowID, at: 2, in: statement, on: handle)
            try database.bind(text: job.type.rawValue, at: 3, in: statement, on: handle)
            try database.bind(text: job.status.rawValue, at: 4, in: statement, on: handle)
            try database.bind(int: job.attempt, at: 5, in: statement, on: handle)
            try database.bind(int: job.maxAttempts, at: 6, in: statement, on: handle)
            try database.bind(int: job.priority, at: 7, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: job.runAfter), at: 8, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: job.claimedAt), at: 9, in: statement, on: handle)
            try database.bind(text: job.claimedBy, at: 10, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: job.createdAt), at: 11, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: job.updatedAt), at: 12, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: job.startedAt), at: 13, in: statement, on: handle)
            try database.bind(text: database.iso8601String(from: job.completedAt), at: 14, in: statement, on: handle)
            try database.bind(text: job.lastError, at: 15, in: statement, on: handle)
            try database.bind(text: job.payloadJSON, at: 16, in: statement, on: handle)
            try database.bind(text: job.resultJSON, at: 17, in: statement, on: handle)
            try database.stepExpectDone(statement, on: handle)
        }
    }

    public func list(status: PipelineJobStatus?) async throws -> [PipelineJob] {
        try database.withConnection { handle in
            let sql: String
            if status != nil {
                sql = """
                SELECT id, workflow_id, type, status, attempt, max_attempts, priority,
                       run_after, claimed_at, claimed_by, created_at, updated_at,
                       started_at, completed_at, last_error, payload_json, result_json
                FROM jobs
                WHERE status = ?
                ORDER BY created_at DESC;
                """
            } else {
                sql = """
                SELECT id, workflow_id, type, status, attempt, max_attempts, priority,
                       run_after, claimed_at, claimed_by, created_at, updated_at,
                       started_at, completed_at, last_error, payload_json, result_json
                FROM jobs
                ORDER BY created_at DESC;
                """
            }

            let statement = try database.prepare(sql, on: handle)
            defer { sqlite3_finalize(statement) }

            if let status {
                try database.bind(text: status.rawValue, at: 1, in: statement, on: handle)
            }

            var jobs: [PipelineJob] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    jobs.append(try decodeJob(from: statement))
                } else if result == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteDatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
                }
            }
            return jobs
        }
    }

    public func find(id: String) async throws -> PipelineJob? {
        try database.withConnection { handle in
            let statement = try database.prepare(
                """
                SELECT id, workflow_id, type, status, attempt, max_attempts, priority,
                       run_after, claimed_at, claimed_by, created_at, updated_at,
                       started_at, completed_at, last_error, payload_json, result_json
                FROM jobs
                WHERE id = ?
                LIMIT 1;
                """,
                on: handle
            )
            defer { sqlite3_finalize(statement) }

            try database.bind(text: id, at: 1, in: statement, on: handle)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                return try decodeJob(from: statement)
            }
            if result == SQLITE_DONE {
                return nil
            }
            throw SQLiteDatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func claimNextRunnable(workerID: String, now: Date) async throws -> PipelineJob? {
        try database.withConnection { handle in
            try database.execute("BEGIN IMMEDIATE TRANSACTION;", on: handle)
            do {
                let select = try database.prepare(
                    """
                    SELECT id, workflow_id, type, status, attempt, max_attempts, priority,
                           run_after, claimed_at, claimed_by, created_at, updated_at,
                           started_at, completed_at, last_error, payload_json, result_json
                    FROM jobs
                    WHERE status = ? AND run_after <= ?
                    ORDER BY priority ASC, created_at ASC
                    LIMIT 1;
                    """,
                    on: handle
                )
                defer { sqlite3_finalize(select) }

                let nowText = database.iso8601String(from: now)
                try database.bind(text: PipelineJobStatus.queued.rawValue, at: 1, in: select, on: handle)
                try database.bind(text: nowText, at: 2, in: select, on: handle)

                guard sqlite3_step(select) == SQLITE_ROW else {
                    try database.execute("COMMIT;", on: handle)
                    return nil
                }

                var job = try decodeJob(from: select)

                let update = try database.prepare(
                    """
                    UPDATE jobs
                    SET status = ?,
                        attempt = attempt + 1,
                        claimed_at = ?,
                        claimed_by = ?,
                        started_at = COALESCE(started_at, ?),
                        updated_at = ?,
                        last_error = NULL
                    WHERE id = ?;
                    """,
                    on: handle
                )
                defer { sqlite3_finalize(update) }

                try database.bind(text: PipelineJobStatus.running.rawValue, at: 1, in: update, on: handle)
                try database.bind(text: nowText, at: 2, in: update, on: handle)
                try database.bind(text: workerID, at: 3, in: update, on: handle)
                try database.bind(text: nowText, at: 4, in: update, on: handle)
                try database.bind(text: nowText, at: 5, in: update, on: handle)
                try database.bind(text: job.id, at: 6, in: update, on: handle)
                try database.stepExpectDone(update, on: handle)

                try database.execute("COMMIT;", on: handle)

                job.status = .running
                job.attempt += 1
                job.claimedAt = now
                job.claimedBy = workerID
                job.startedAt = job.startedAt ?? now
                job.updatedAt = now
                job.lastError = nil
                return job
            } catch {
                try? database.execute("ROLLBACK;", on: handle)
                throw error
            }
        }
    }

    public func markSucceeded(id: String, completedAt: Date, resultJSON: String) async throws {
        try database.withConnection { handle in
            let statement = try database.prepare(
                """
                UPDATE jobs
                SET status = ?, completed_at = ?, updated_at = ?, result_json = ?, last_error = NULL
                WHERE id = ?;
                """,
                on: handle
            )
            defer { sqlite3_finalize(statement) }

            let completedAtText = database.iso8601String(from: completedAt)
            try database.bind(text: PipelineJobStatus.succeeded.rawValue, at: 1, in: statement, on: handle)
            try database.bind(text: completedAtText, at: 2, in: statement, on: handle)
            try database.bind(text: completedAtText, at: 3, in: statement, on: handle)
            try database.bind(text: resultJSON, at: 4, in: statement, on: handle)
            try database.bind(text: id, at: 5, in: statement, on: handle)
            try database.stepExpectDone(statement, on: handle)
        }
    }

    public func markFailed(id: String, completedAt: Date, errorMessage: String) async throws {
        try database.withConnection { handle in
            let statement = try database.prepare(
                """
                UPDATE jobs
                SET status = ?, completed_at = ?, updated_at = ?, last_error = ?
                WHERE id = ?;
                """,
                on: handle
            )
            defer { sqlite3_finalize(statement) }

            let completedAtText = database.iso8601String(from: completedAt)
            try database.bind(text: PipelineJobStatus.failed.rawValue, at: 1, in: statement, on: handle)
            try database.bind(text: completedAtText, at: 2, in: statement, on: handle)
            try database.bind(text: completedAtText, at: 3, in: statement, on: handle)
            try database.bind(text: errorMessage, at: 4, in: statement, on: handle)
            try database.bind(text: id, at: 5, in: statement, on: handle)
            try database.stepExpectDone(statement, on: handle)
        }
    }

    private func decodeJob(from statement: OpaquePointer) throws -> PipelineJob {
        let type = PipelineJobType(rawValue: string(at: 2, in: statement)) ?? .chartIngest
        let status = PipelineJobStatus(rawValue: string(at: 3, in: statement)) ?? .queued

        return PipelineJob(
            id: string(at: 0, in: statement),
            workflowID: string(at: 1, in: statement),
            type: type,
            status: status,
            attempt: Int(sqlite3_column_int64(statement, 4)),
            maxAttempts: Int(sqlite3_column_int64(statement, 5)),
            priority: Int(sqlite3_column_int64(statement, 6)),
            runAfter: database.date(from: optionalString(at: 7, in: statement)) ?? Date(),
            claimedAt: database.date(from: optionalString(at: 8, in: statement)),
            claimedBy: optionalString(at: 9, in: statement),
            createdAt: database.date(from: optionalString(at: 10, in: statement)) ?? Date(),
            updatedAt: database.date(from: optionalString(at: 11, in: statement)) ?? Date(),
            startedAt: database.date(from: optionalString(at: 12, in: statement)),
            completedAt: database.date(from: optionalString(at: 13, in: statement)),
            lastError: optionalString(at: 14, in: statement),
            payloadJSON: string(at: 15, in: statement),
            resultJSON: optionalString(at: 16, in: statement)
        )
    }

    private func string(at index: Int32, in statement: OpaquePointer) -> String {
        optionalString(at: index, in: statement) ?? ""
    }

    private func optionalString(at index: Int32, in statement: OpaquePointer) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}
