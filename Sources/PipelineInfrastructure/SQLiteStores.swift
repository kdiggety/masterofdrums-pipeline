import Foundation
import PipelineApplication
import PipelineDomain

public actor SQLiteWorkflowStore: WorkflowStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func insert(_ workflow: PipelineWorkflow) async throws {
        _ = database
        // Real SQLite insert implementation to be added next.
    }
}

public actor SQLiteJobStore: JobStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func enqueue(_ job: PipelineJob) async throws {
        _ = database
        // Real SQLite insert implementation to be added next.
    }

    public func list(status: PipelineJobStatus?) async throws -> [PipelineJob] {
        _ = database
        _ = status
        return []
    }

    public func find(id: String) async throws -> PipelineJob? {
        _ = database
        _ = id
        return nil
    }
}
