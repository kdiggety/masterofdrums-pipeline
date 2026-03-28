import Foundation
import PipelineDomain

public protocol JobStore: Sendable {
    func enqueue(_ job: PipelineJob) async throws
    func listQueuedJobs() async throws -> [PipelineJob]
}

public struct SubmitChartIngestJob {
    public let store: JobStore

    public init(store: JobStore) {
        self.store = store
    }

    public func execute(source: ChartAssetReference, requestedBy: String) async throws -> PipelineJob {
        let workflow = PipelineWorkflow(name: "chart-ingest")
        let job = PipelineJob(
            workflowID: workflow.id,
            type: .chartIngest,
            payload: [
                "sourceType": source.sourceType,
                "sourceURI": source.sourceURI,
                "requestedBy": requestedBy
            ]
        )
        try await store.enqueue(job)
        return job
    }
}
