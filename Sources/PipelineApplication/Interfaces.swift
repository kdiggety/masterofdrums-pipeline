import Foundation
import PipelineDomain

public protocol DatabaseMigrator: Sendable {
    func applyMigrations() async throws
}

public protocol WorkflowStore: Sendable {
    func insert(_ workflow: PipelineWorkflow) async throws
    func markRunning(id: String, startedAt: Date) async throws
    func markFinished(id: String, status: PipelineWorkflowStatus, completedAt: Date, lastError: String?) async throws
}

public protocol WorkflowEventStore: Sendable {
    func append(_ event: PipelineWorkflowEvent) async throws
    func list(workflowID: String?, jobID: String?, limit: Int) async throws -> [PipelineWorkflowEvent]
}

public protocol JobStore: Sendable {
    func enqueue(_ job: PipelineJob) async throws
    func list(status: PipelineJobStatus?) async throws -> [PipelineJob]
    func find(id: String) async throws -> PipelineJob?
    func claimNextRunnable(workerID: String, now: Date) async throws -> PipelineJob?
    func markSucceeded(id: String, completedAt: Date, resultJSON: String) async throws
    func markFailed(id: String, completedAt: Date, errorMessage: String, retryAt: Date?) async throws
}

public struct EnqueueChartIngestRequest: Sendable {
    public let source: ChartAssetReference
    public let requestedBy: String
    public let idempotencyKey: String?
    public let maxAttempts: Int

    public init(
        source: ChartAssetReference,
        requestedBy: String = "cli",
        idempotencyKey: String? = nil,
        maxAttempts: Int = 5
    ) {
        self.source = source
        self.requestedBy = requestedBy
        self.idempotencyKey = idempotencyKey
        self.maxAttempts = maxAttempts
    }
}

public struct SubmitChartIngestJob {
    public let workflows: WorkflowStore
    public let jobs: JobStore

    public init(workflows: WorkflowStore, jobs: JobStore) {
        self.workflows = workflows
        self.jobs = jobs
    }

    public func execute(_ request: EnqueueChartIngestRequest) async throws -> PipelineJob {
        let workflow = PipelineWorkflow(
            name: "chart-ingest",
            status: .queued,
            requestedBy: request.requestedBy,
            idempotencyKey: request.idempotencyKey
        )
        try await workflows.insert(workflow)

        let payload = ChartIngestPayload(
            sourceType: request.source.sourceType,
            sourceURI: request.source.sourceURI,
            requestedBy: request.requestedBy,
            idempotencyKey: request.idempotencyKey
        )
        let job = PipelineJob(
            workflowID: workflow.id,
            type: .chartIngest,
            status: .queued,
            maxAttempts: request.maxAttempts,
            payloadJSON: payload.toJSONString()
        )
        try await jobs.enqueue(job)
        return job
    }
}

public struct ChartIngestPayload: Codable, Sendable {
    public let sourceType: String
    public let sourceURI: String
    public let requestedBy: String
    public let idempotencyKey: String?

    public init(sourceType: String, sourceURI: String, requestedBy: String, idempotencyKey: String?) {
        self.sourceType = sourceType
        self.sourceURI = sourceURI
        self.requestedBy = requestedBy
        self.idempotencyKey = idempotencyKey
    }

    public func toJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
