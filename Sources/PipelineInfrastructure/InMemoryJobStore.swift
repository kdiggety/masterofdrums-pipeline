import Foundation
import PipelineApplication
import PipelineDomain

public actor InMemoryJobStore: JobStore {
    private var jobs: [PipelineJob] = []

    public init() {}

    public func enqueue(_ job: PipelineJob) async throws {
        jobs.append(job)
    }

    public func listQueuedJobs() async throws -> [PipelineJob] {
        jobs.filter { $0.status == .queued }
    }
}
