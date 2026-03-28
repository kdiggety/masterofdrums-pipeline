import Foundation

public enum PipelineJobType: String, Codable, Sendable {
    case chartIngest = "chart_ingest"
    case chartValidate = "chart_validate"
    case chartExport = "chart_export"
}

public enum PipelineJobStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public struct PipelineJob: Codable, Identifiable, Sendable {
    public let id: String
    public let workflowID: String
    public let type: PipelineJobType
    public var status: PipelineJobStatus
    public var attempt: Int
    public var maxAttempts: Int
    public var payload: [String: String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        workflowID: String,
        type: PipelineJobType,
        status: PipelineJobStatus = .queued,
        attempt: Int = 0,
        maxAttempts: Int = 5,
        payload: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workflowID = workflowID
        self.type = type
        self.status = status
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PipelineWorkflow: Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public struct ChartAssetReference: Codable, Sendable {
    public let sourceType: String
    public let sourceURI: String

    public init(sourceType: String, sourceURI: String) {
        self.sourceType = sourceType
        self.sourceURI = sourceURI
    }
}
