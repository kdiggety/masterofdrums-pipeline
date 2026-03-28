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

public enum PipelineWorkflowStatus: String, Codable, Sendable {
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
    public var priority: Int
    public var runAfter: Date
    public var claimedAt: Date?
    public var claimedBy: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var lastError: String?
    public var payloadJSON: String
    public var resultJSON: String?

    public init(
        id: String = UUID().uuidString,
        workflowID: String,
        type: PipelineJobType,
        status: PipelineJobStatus = .queued,
        attempt: Int = 0,
        maxAttempts: Int = 5,
        priority: Int = 100,
        runAfter: Date = Date(),
        claimedAt: Date? = nil,
        claimedBy: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        lastError: String? = nil,
        payloadJSON: String = "{}",
        resultJSON: String? = nil
    ) {
        self.id = id
        self.workflowID = workflowID
        self.type = type
        self.status = status
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.priority = priority
        self.runAfter = runAfter
        self.claimedAt = claimedAt
        self.claimedBy = claimedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastError = lastError
        self.payloadJSON = payloadJSON
        self.resultJSON = resultJSON
    }
}

public struct PipelineWorkflow: Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var status: PipelineWorkflowStatus
    public var requestedBy: String?
    public var idempotencyKey: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var lastError: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        status: PipelineWorkflowStatus = .queued,
        requestedBy: String? = nil,
        idempotencyKey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.requestedBy = requestedBy
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastError = lastError
    }
}

public struct PipelineWorkflowEvent: Codable, Identifiable, Sendable {
    public let id: String
    public let workflowID: String
    public let jobID: String?
    public let eventType: String
    public let message: String?
    public let detailsJSON: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        workflowID: String,
        jobID: String? = nil,
        eventType: String,
        message: String? = nil,
        detailsJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workflowID = workflowID
        self.jobID = jobID
        self.eventType = eventType
        self.message = message
        self.detailsJSON = detailsJSON
        self.createdAt = createdAt
    }
}

public struct ArtifactRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let workflowID: String?
    public let jobID: String?
    public let artifactType: String
    public let uri: String
    public let contentType: String?
    public let checksum: String?
    public let metadataJSON: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        workflowID: String? = nil,
        jobID: String? = nil,
        artifactType: String,
        uri: String,
        contentType: String? = nil,
        checksum: String? = nil,
        metadataJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workflowID = workflowID
        self.jobID = jobID
        self.artifactType = artifactType
        self.uri = uri
        self.contentType = contentType
        self.checksum = checksum
        self.metadataJSON = metadataJSON
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
