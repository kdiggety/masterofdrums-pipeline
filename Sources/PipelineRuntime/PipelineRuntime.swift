import Foundation
import PipelineApplication
import PipelineDomain
import PipelineInfrastructure

public enum PipelineCLICommand: Equatable {
    case initDB
    case worker
    case enqueueChartIngest(sourceURI: String, sourceType: String, requestedBy: String, idempotencyKey: String?)
    case listJobs(status: PipelineJobStatus?)
    case showJob(id: String)
    case help
}

public struct PipelineRuntime {
    public let database: SQLiteDatabase
    public let migrator: DatabaseMigrator
    public let workflows: WorkflowStore
    public let jobs: JobStore

    public init(configuration: SQLiteConfiguration = .fromEnvironment()) {
        let database = SQLiteDatabase(configuration: configuration)
        self.database = database
        self.migrator = SQLiteMigrator(database: database)
        self.workflows = SQLiteWorkflowStore(database: database)
        self.jobs = SQLiteJobStore(database: database)
    }

    public func run(command: PipelineCLICommand) async throws {
        switch command {
        case .initDB:
            try await migrator.applyMigrations()
            print("[pipeline] database initialized at \(database.openDescription())")

        case .worker:
            if database.configuration.autoMigrate {
                try await migrator.applyMigrations()
            }
            try await runWorkerLoop()

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
                print("result: \(job.resultJSON ?? \"<none>\")")
            } else {
                print("[pipeline] job not found: \(id)")
            }

        case .help:
            print(Self.helpText)
        }
    }

    private func runWorkerLoop() async throws {
        let workerID = Self.defaultWorkerID()
        print("[pipeline] worker starting")
        print("[pipeline] database: \(database.openDescription())")
        print("[pipeline] worker id: \(workerID)")

        while true {
            let now = Date()
            if let job = try await jobs.claimNextRunnable(workerID: workerID, now: now) {
                print("[pipeline] claimed job \(job.id) type=\(job.type.rawValue) attempt=\(job.attempt)")
                try await workflows.markRunning(id: job.workflowID, startedAt: now)
                do {
                    let resultJSON = try execute(job: job, now: now)
                    let completedAt = Date()
                    try await jobs.markSucceeded(id: job.id, completedAt: completedAt, resultJSON: resultJSON)
                    try await workflows.markFinished(id: job.workflowID, status: .succeeded, completedAt: completedAt, lastError: nil)
                    print("[pipeline] job succeeded \(job.id)")
                } catch {
                    let completedAt = Date()
                    let message = error.localizedDescription
                    try await jobs.markFailed(id: job.id, completedAt: completedAt, errorMessage: message)
                    try await workflows.markFinished(id: job.workflowID, status: .failed, completedAt: completedAt, lastError: message)
                    print("[pipeline] job failed \(job.id): \(message)")
                }
            } else {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
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

    private static func defaultWorkerID() -> String {
        let host = ProcessInfo.processInfo.hostName
        return "\(host)-\(UUID().uuidString.prefix(8))"
    }

    public static let helpText = """
    MasterOfDrums Pipeline

    Commands:
      init-db
      worker
      enqueue-chart-ingest --source-uri <uri> [--source-type midi] [--requested-by cli] [--idempotency-key <key>]
      list-jobs [--status queued|running|failed|succeeded|cancelled]
      show-job <job-id>
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
            return .worker
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
        default:
            return .help
        }
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
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
