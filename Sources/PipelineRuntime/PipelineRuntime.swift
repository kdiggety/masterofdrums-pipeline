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
            print("[pipeline] worker starting")
            print("[pipeline] database: \(database.openDescription())")
            print("[pipeline] worker loop not yet implemented")

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
                print("result: \(job.resultJSON ?? "<none>")")
            } else {
                print("[pipeline] job not found: \(id)")
            }

        case .help:
            print(Self.helpText)
        }
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
