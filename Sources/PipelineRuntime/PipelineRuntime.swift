import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import PipelineApplication
import PipelineDomain
import PipelineInfrastructure

public enum PipelineCLICommand: Equatable {
    case initDB
    case worker(stopAfterIdlePolls: Int?)
    case enqueueChartIngest(sourceURI: String, sourceType: String, requestedBy: String, idempotencyKey: String?)
    case listJobs(status: PipelineJobStatus?)
    case showJob(id: String)
    case listEvents(workflowID: String?, jobID: String?, limit: Int)
    case help
}

public struct PipelineRuntime {
    public let database: SQLiteDatabase
    public let migrator: DatabaseMigrator
    public let workflows: WorkflowStore
    public let events: WorkflowEventStore
    public let jobs: JobStore

    public init(configuration: SQLiteConfiguration = .fromEnvironment()) {
        let database = SQLiteDatabase(configuration: configuration)
        self.database = database
        self.migrator = SQLiteMigrator(database: database)
        self.workflows = SQLiteWorkflowStore(database: database)
        self.events = SQLiteWorkflowEventStore(database: database)
        self.jobs = SQLiteJobStore(database: database)
    }

    public func run(command: PipelineCLICommand) async throws {
        switch command {
        case .initDB:
            try await migrator.applyMigrations()
            print("[pipeline] database initialized at \(database.openDescription())")

        case .worker(let stopAfterIdlePolls):
            if database.configuration.autoMigrate {
                try await migrator.applyMigrations()
            }
            try await runWorkerLoop(stopAfterIdlePolls: stopAfterIdlePolls)

        case .enqueueChartIngest(let sourceURI, let sourceType, let requestedBy, let idempotencyKey):
            if database.configuration.autoMigrate {
                try await migrator.applyMigrations()
            }
            let useCase = SubmitChartIngestJob(workflows: workflows, jobs: jobs)
            let job = try await useCase.execute(
                EnqueueChartIngestRequest(
                    source: ChartAssetReference(sourceType: sourceType, sourceURI: sourceURI),
                    requestedBy: requestedBy,
                    idempotencyKey: idempotencyKey
                )
            )
            try await appendEvent(workflowID: job.workflowID, jobID: job.id, eventType: "job_enqueued", message: "Chart ingest job enqueued", details: [
                "source_uri": AnySendable(sourceURI),
                "source_type": AnySendable(sourceType),
                "requested_by": AnySendable(requestedBy)
            ], createdAt: Date())
            print("[pipeline] enqueued chart-ingest job \(job.id) for \(sourceURI)")

        case .listJobs(let status):
            if database.configuration.autoMigrate {
                try await migrator.applyMigrations()
            }
            let results = try await jobs.list(status: status)
            if results.isEmpty {
                print("[pipeline] no jobs found")
            } else {
                for job in results {
                    print("\(job.id) \(job.type.rawValue) \(job.status.rawValue) attempts=\(job.attempt)/\(job.maxAttempts)")
                }
            }

        case .showJob(let id):
            if database.configuration.autoMigrate {
                try await migrator.applyMigrations()
            }
            if let job = try await jobs.find(id: id) {
                print("job: \(job.id)")
                print("workflow: \(job.workflowID)")
                print("type: \(job.type.rawValue)")
                print("status: \(job.status.rawValue)")
                print("payload: \(job.payloadJSON)")
                let resultDescription = job.resultJSON ?? "<none>"
                print("result: \(resultDescription)")
            } else {
                print("[pipeline] job not found: \(id)")
            }

        case .listEvents(let workflowID, let jobID, let limit):
            if database.configuration.autoMigrate {
                try await migrator.applyMigrations()
            }
            let results = try await events.list(workflowID: workflowID, jobID: jobID, limit: limit)
            if results.isEmpty {
                print("[pipeline] no workflow events found")
            } else {
                for event in results {
                    let jobLabel = event.jobID ?? "-"
                    let message = event.message ?? ""
                    print("\(Self.timestamp(event.createdAt)) workflow=\(event.workflowID) job=\(jobLabel) type=\(event.eventType) \(message)")
                }
            }

        case .help:
            print(Self.helpText)
        }
    }

    private func runWorkerLoop(stopAfterIdlePolls: Int?) async throws {
        let workerID = Self.defaultWorkerID()
        let pollInterval = Self.workerPollInterval
        let signalMonitor = WorkerSignalMonitor.install()
        var idlePolls = 0
        var processedJobs = 0

        print("[pipeline] worker starting")
        print("[pipeline] database: \(database.openDescription())")
        print("[pipeline] worker id: \(workerID)")
        let pollIntervalDescription = String(format: "%.2f", pollInterval)
        print("[pipeline] poll interval: \(pollIntervalDescription)s")
        if let stopAfterIdlePolls {
            print("[pipeline] stop-after-idle-polls: \(stopAfterIdlePolls)")
        }

        while !signalMonitor.shouldStop {
            let now = Date()
            if let job = try await jobs.claimNextRunnable(workerID: workerID, now: now) {
                processedJobs += 1
                idlePolls = 0
                let claimedMessage = "Claimed by \(workerID); attempt \(job.attempt)/\(job.maxAttempts)"
                print("[pipeline] claimed job \(job.id) type=\(job.type.rawValue) attempt=\(job.attempt)/\(job.maxAttempts)")
                try await workflows.markRunning(id: job.workflowID, startedAt: now)
                try await appendEvent(workflowID: job.workflowID, jobID: job.id, eventType: "job_claimed", message: claimedMessage, details: [
                    "worker_id": AnySendable(workerID),
                    "attempt": AnySendable(job.attempt),
                    "max_attempts": AnySendable(job.maxAttempts),
                    "job_type": AnySendable(job.type.rawValue)
                ], createdAt: now)

                do {
                    let resultJSON = try execute(job: job, now: now)
                    let completedAt = Date()
                    try await jobs.markSucceeded(id: job.id, completedAt: completedAt, resultJSON: resultJSON)
                    try await workflows.markFinished(id: job.workflowID, status: .succeeded, completedAt: completedAt, lastError: nil)
                    try await appendEvent(workflowID: job.workflowID, jobID: job.id, eventType: "job_succeeded", message: "Job completed successfully", details: [
                        "worker_id": AnySendable(workerID),
                        "result_json": AnySendable(resultJSON)
                    ], createdAt: completedAt)
                    print("[pipeline] job succeeded \(job.id)")
                } catch {
                    let completedAt = Date()
                    let message = Self.describe(error: error)
                    let retryAt = nextRetryDate(for: job, from: completedAt)
                    try await jobs.markFailed(id: job.id, completedAt: completedAt, errorMessage: message, retryAt: retryAt)

                    if let retryAt {
                        try await appendEvent(workflowID: job.workflowID, jobID: job.id, eventType: "job_requeued", message: message, details: [
                            "worker_id": AnySendable(workerID),
                            "retry_at": AnySendable(Self.timestamp(retryAt)),
                            "attempt": AnySendable(job.attempt),
                            "max_attempts": AnySendable(job.maxAttempts)
                        ], createdAt: completedAt)
                        print("[pipeline] job failed \(job.id): \(message)")
                        print("[pipeline] requeued job \(job.id) for retry at \(Self.timestamp(retryAt))")
                    } else {
                        try await workflows.markFinished(id: job.workflowID, status: .failed, completedAt: completedAt, lastError: message)
                        try await appendEvent(workflowID: job.workflowID, jobID: job.id, eventType: "job_failed", message: message, details: [
                            "worker_id": AnySendable(workerID),
                            "attempt": AnySendable(job.attempt),
                            "max_attempts": AnySendable(job.maxAttempts)
                        ], createdAt: completedAt)
                        print("[pipeline] job failed permanently \(job.id): \(message)")
                    }
                }
            } else {
                idlePolls += 1
                if idlePolls == 1 || idlePolls % Self.idleLogEveryPolls == 0 {
                    print("[pipeline] idle; waiting for runnable jobs")
                }
                if let stopAfterIdlePolls, idlePolls >= stopAfterIdlePolls {
                    print("[pipeline] stop-after-idle reached; processed \(processedJobs) job(s)")
                    break
                }
                try await Self.sleep(seconds: pollInterval)
            }
        }

        print("[pipeline] worker stopping")
    }

    private func execute(job: PipelineJob, now: Date) throws -> String {
        switch job.type {
        case .chartIngest:
            return try executeChartIngest(job: job, now: now)
        case .chartValidate, .chartExport:
            throw PipelineRuntimeError.unsupportedJobType(job.type.rawValue)
        }
    }

    private func executeChartIngest(job: PipelineJob, now: Date) throws -> String {
        let payload = try decodeChartIngestPayload(from: job.payloadJSON)
        let sourceURL = URL(fileURLWithPath: payload.sourceURI)
        let reachableURL: URL

        if FileManager.default.fileExists(atPath: payload.sourceURI) {
            reachableURL = URL(fileURLWithPath: payload.sourceURI)
        } else if payload.sourceURI.hasPrefix("file://") {
            reachableURL = URL(string: payload.sourceURI) ?? sourceURL
        } else {
            throw PipelineRuntimeError.sourceNotFound(payload.sourceURI)
        }

        let filePath = reachableURL.isFileURL ? reachableURL.path : payload.sourceURI
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw PipelineRuntimeError.sourceNotFound(payload.sourceURI)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let result = ChartIngestResult(
            sourceType: payload.sourceType,
            sourceURI: payload.sourceURI,
            requestedBy: payload.requestedBy,
            filePath: filePath,
            fileSizeBytes: fileSize,
            ingestedAt: now,
            note: "Chart ingest placeholder completed. Parsing/export pipeline not wired yet."
        )
        return result.toJSONString()
    }

    private func decodeChartIngestPayload(from json: String) throws -> ChartIngestPayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ChartIngestPayload.self, from: data)
    }

    private func appendEvent(
        workflowID: String,
        jobID: String?,
        eventType: String,
        message: String?,
        details: [String: AnySendable],
        createdAt: Date
    ) async throws {
        let event = PipelineWorkflowEvent(
            workflowID: workflowID,
            jobID: jobID,
            eventType: eventType,
            message: message,
            detailsJSON: Self.encodeJSONObject(details),
            createdAt: createdAt
        )
        try await events.append(event)
    }

    private func nextRetryDate(for job: PipelineJob, from completedAt: Date) -> Date? {
        guard job.attempt < job.maxAttempts else { return nil }
        let delaySeconds = min(pow(2.0, Double(max(job.attempt - 1, 0))), Self.maxRetryDelaySeconds)
        return completedAt.addingTimeInterval(delaySeconds)
    }

    private static func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func describe(error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        return String(describing: error)
    }

    private static func encodeJSONObject(_ values: [String: AnySendable]) -> String? {
        let rawValues = values.mapValues(\.value)
        guard JSONSerialization.isValidJSONObject(rawValues) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: rawValues, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func timestamp(_ date: Date) -> String {
        workerTimestampFormatter.string(from: date)
    }

    private static func defaultWorkerID() -> String {
        let host = ProcessInfo.processInfo.hostName
        return "\(host)-\(UUID().uuidString.prefix(8))"
    }

    private static let workerPollInterval: TimeInterval = {
        let rawValue = ProcessInfo.processInfo.environment["PIPELINE_WORKER_POLL_INTERVAL_SECONDS"]
        if let rawValue, let seconds = TimeInterval(rawValue), seconds > 0 {
            return seconds
        }
        return 1
    }()

    private static let maxRetryDelaySeconds: Double = 60
    private static let idleLogEveryPolls = 30
    private static let workerTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static let helpText = """
    MasterOfDrums Pipeline

    Commands:
      init-db
      worker [--stop-after-idle-polls <count>]
      enqueue-chart-ingest --source-uri <uri> [--source-type midi] [--requested-by cli] [--idempotency-key <key>]
      list-jobs [--status queued|running|failed|succeeded|cancelled]
      show-job <job-id>
      list-events [--workflow-id <workflow-id>] [--job-id <job-id>] [--limit <count>]

    Worker environment:
      PIPELINE_WORKER_POLL_INTERVAL_SECONDS  Seconds to wait between empty polls (default: 1)
    """
}

public enum PipelineCLIParser {
    public static func parse(arguments: [String]) -> PipelineCLICommand {
        guard arguments.count > 1 else { return .help }
        let args = Array(arguments.dropFirst())
        guard let command = args.first else { return .help }

        switch command {
        case "init-db":
            return .initDB
        case "worker":
            return .worker(stopAfterIdlePolls: intValue(for: "--stop-after-idle-polls", in: args))
        case "enqueue-chart-ingest":
            return .enqueueChartIngest(
                sourceURI: value(for: "--source-uri", in: args) ?? "",
                sourceType: value(for: "--source-type", in: args) ?? "midi",
                requestedBy: value(for: "--requested-by", in: args) ?? "cli",
                idempotencyKey: value(for: "--idempotency-key", in: args)
            )
        case "list-jobs":
            let rawStatus = value(for: "--status", in: args)
            return .listJobs(status: rawStatus.flatMap(PipelineJobStatus.init(rawValue:)))
        case "show-job":
            if args.count >= 2 {
                return .showJob(id: args[1])
            }
            return .help
        case "list-events":
            return .listEvents(
                workflowID: value(for: "--workflow-id", in: args),
                jobID: value(for: "--job-id", in: args),
                limit: intValue(for: "--limit", in: args) ?? 50
            )
        default:
            return .help
        }
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func intValue(for flag: String, in args: [String]) -> Int? {
        guard let rawValue = value(for: flag, in: args) else { return nil }
        return Int(rawValue)
    }
}

public enum PipelineRuntimeError: LocalizedError {
    case sourceNotFound(String)
    case unsupportedJobType(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let sourceURI):
            return "Source file not found: \(sourceURI)"
        case .unsupportedJobType(let type):
            return "Unsupported job type: \(type)"
        }
    }
}

public struct ChartIngestResult: Codable, Sendable {
    public let sourceType: String
    public let sourceURI: String
    public let requestedBy: String
    public let filePath: String
    public let fileSizeBytes: Int
    public let ingestedAt: Date
    public let note: String

    public func toJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct AnySendable: @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }
}

private final class WorkerSignalMonitor: @unchecked Sendable {
    static let shared = WorkerSignalMonitor()

    private let lock = NSLock()
    private var stopRequested = false

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    static func install() -> WorkerSignalMonitor {
        signal(SIGINT, pipelineSignalHandler)
        signal(SIGTERM, pipelineSignalHandler)
        return shared
    }
}

private func pipelineSignalHandler(_ signal: Int32) -> Void {
    _ = signal
    WorkerSignalMonitor.shared.requestStop()
}
