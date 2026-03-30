import Foundation
import AVFoundation
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
    case enqueueAudioIngest(sourceURI: String, sourceType: String, requestedBy: String, idempotencyKey: String?)
    case listJobs(status: PipelineJobStatus?)
    case showJob(id: String)
    case listEvents(workflowID: String?, jobID: String?, limit: Int)
    case listArtifacts(workflowID: String?, jobID: String?, limit: Int)
    case help
}

public struct PipelineRuntime {
    public let database: SQLiteDatabase
    public let migrator: DatabaseMigrator
    public let workflows: WorkflowStore
    public let events: WorkflowEventStore
    public let artifacts: ArtifactStore
    public let jobs: JobStore

    public init(configuration: SQLiteConfiguration = .fromEnvironment()) {
        let database = SQLiteDatabase(configuration: configuration)
        self.database = database
        self.migrator = SQLiteMigrator(database: database)
        self.workflows = SQLiteWorkflowStore(database: database)
        self.events = SQLiteWorkflowEventStore(database: database)
        self.artifacts = SQLiteArtifactStore(database: database)
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

        case .enqueueAudioIngest(let sourceURI, let sourceType, let requestedBy, let idempotencyKey):
            if database.configuration.autoMigrate {
                try await migrator.applyMigrations()
            }
            let useCase = SubmitAudioIngestJob(workflows: workflows, jobs: jobs)
            let job = try await useCase.execute(
                EnqueueAudioIngestRequest(
                    source: AudioAssetReference(sourceType: sourceType, sourceURI: sourceURI),
                    requestedBy: requestedBy,
                    idempotencyKey: idempotencyKey
                )
            )
            try await appendEvent(
                workflowID: job.workflowID,
                jobID: job.id,
                eventType: "job_enqueued",
                message: "Audio ingest job enqueued",
                details: [
                    "source_uri": AnySendable(sourceURI),
                    "source_type": AnySendable(sourceType),
                    "requested_by": AnySendable(requestedBy)
                ],
                createdAt: Date()
            )
            print("[pipeline] enqueued audio-ingest job \(job.id) for \(sourceURI)")

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
                    print("\(Self.timestamp(event.createdAt)) workflow=\(event.workflowID) job=\(jobLabel) type=\(event.eventType) \(event.message ?? "")")
                }
            }

        case .listArtifacts(let workflowID, let jobID, let limit):
            if database.configuration.autoMigrate {
                try await migrator.applyMigrations()
            }
            let results = try await artifacts.list(workflowID: workflowID, jobID: jobID, limit: limit)
            if results.isEmpty {
                print("[pipeline] no artifacts found")
            } else {
                for artifact in results {
                    let workflowLabel = artifact.workflowID ?? "-"
                    let jobLabel = artifact.jobID ?? "-"
                    print("\(Self.timestamp(artifact.createdAt)) workflow=\(workflowLabel) job=\(jobLabel) type=\(artifact.artifactType) uri=\(artifact.uri)")
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
                print("[pipeline] claimed job \(job.id) type=\(job.type.rawValue) attempt=\(job.attempt)/\(job.maxAttempts)")
                try await workflows.markRunning(id: job.workflowID, startedAt: now)
                try await appendEvent(
                    workflowID: job.workflowID,
                    jobID: job.id,
                    eventType: "job_claimed",
                    message: "Claimed by \(workerID); attempt \(job.attempt)/\(job.maxAttempts)",
                    details: [
                        "worker_id": AnySendable(workerID),
                        "attempt": AnySendable(job.attempt),
                        "max_attempts": AnySendable(job.maxAttempts),
                        "job_type": AnySendable(job.type.rawValue)
                    ],
                    createdAt: now
                )

                do {
                    let resultJSON = try await execute(job: job, now: now)
                    let completedAt = Date()
                    try await jobs.markSucceeded(id: job.id, completedAt: completedAt, resultJSON: resultJSON)
                    try await workflows.markFinished(id: job.workflowID, status: .succeeded, completedAt: completedAt, lastError: nil)
                    try await appendEvent(
                        workflowID: job.workflowID,
                        jobID: job.id,
                        eventType: "job_succeeded",
                        message: "Job completed successfully",
                        details: [
                            "worker_id": AnySendable(workerID),
                            "result_json": AnySendable(resultJSON)
                        ],
                        createdAt: completedAt
                    )
                    print("[pipeline] job succeeded \(job.id)")
                } catch {
                    let completedAt = Date()
                    let message = Self.describe(error: error)
                    let retryAt = nextRetryDate(for: job, from: completedAt)
                    try await jobs.markFailed(id: job.id, completedAt: completedAt, errorMessage: message, retryAt: retryAt)

                    if let retryAt {
                        try await appendEvent(
                            workflowID: job.workflowID,
                            jobID: job.id,
                            eventType: "job_requeued",
                            message: message,
                            details: [
                                "worker_id": AnySendable(workerID),
                                "retry_at": AnySendable(Self.timestamp(retryAt)),
                                "attempt": AnySendable(job.attempt),
                                "max_attempts": AnySendable(job.maxAttempts)
                            ],
                            createdAt: completedAt
                        )
                        print("[pipeline] job failed \(job.id): \(message)")
                        print("[pipeline] requeued job \(job.id) for retry at \(Self.timestamp(retryAt))")
                    } else {
                        try await workflows.markFinished(id: job.workflowID, status: .failed, completedAt: completedAt, lastError: message)
                        try await appendEvent(
                            workflowID: job.workflowID,
                            jobID: job.id,
                            eventType: "job_failed",
                            message: message,
                            details: [
                                "worker_id": AnySendable(workerID),
                                "attempt": AnySendable(job.attempt),
                                "max_attempts": AnySendable(job.maxAttempts)
                            ],
                            createdAt: completedAt
                        )
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

    private func execute(job: PipelineJob, now: Date) async throws -> String {
        switch job.type {
        case .audioIngest:
            return try await executeAudioIngest(job: job, now: now)
        case .audioAnalyze:
            return try await executeAudioAnalyze(job: job, now: now)
        case .chartGenerate, .chartValidate, .chartExport:
            throw PipelineRuntimeError.unsupportedJobType(job.type.rawValue)
        }
    }

    private func executeAudioIngest(job: PipelineJob, now: Date) async throws -> String {
        let payload = try decodeAudioIngestPayload(from: job.payloadJSON)
        let fileURL = try resolveLocalFileURL(from: payload.sourceURI)
        let filePath = fileURL.path
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: filePath) else {
            throw PipelineRuntimeError.sourceNotFound(payload.sourceURI)
        }

        let attributes = try fileManager.attributesOfItem(atPath: filePath)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date
        let contentType = Self.contentType(for: fileURL)

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let firstTrack = tracks.first
        let formatDescriptions = try await firstTrack?.load(.formatDescriptions)

        let metadata = AudioIngestResult(
            sourceType: payload.sourceType,
            sourceURI: payload.sourceURI,
            requestedBy: payload.requestedBy,
            filePath: filePath,
            fileSizeBytes: fileSize,
            contentType: contentType,
            durationSeconds: durationSeconds.isFinite ? durationSeconds : nil,
            audioTrackCount: tracks.count,
            sampleRate: Self.sampleRate(from: formatDescriptions),
            channelCount: Self.channelCount(from: formatDescriptions),
            modifiedAt: modifiedAt,
            ingestedAt: now,
            note: "Audio source verified and metadata extracted."
        )

        let artifact = ArtifactRecord(
            workflowID: job.workflowID,
            jobID: job.id,
            artifactType: "source_audio",
            uri: fileURL.absoluteString,
            contentType: contentType,
            checksum: nil,
            metadataJSON: metadata.toJSONString(),
            createdAt: now
        )
        try await artifacts.insert(artifact)
        try await appendEvent(
            workflowID: job.workflowID,
            jobID: job.id,
            eventType: "audio_metadata_extracted",
            message: "Audio metadata extracted",
            details: [
                "content_type": AnySendable(contentType ?? "unknown"),
                "duration_seconds": AnySendable(metadata.durationSeconds ?? 0),
                "audio_track_count": AnySendable(metadata.audioTrackCount),
                "sample_rate": AnySendable(metadata.sampleRate ?? 0),
                "channel_count": AnySendable(metadata.channelCount ?? 0)
            ],
            createdAt: now
        )

        let analyzeJob = try await enqueueAudioAnalyzeFollowUp(for: job, payload: payload, createdAt: now)
        try await appendEvent(
            workflowID: job.workflowID,
            jobID: job.id,
            eventType: "audio_analyze_enqueued",
            message: "Enqueued follow-up audio_analyze job \(analyzeJob.id)",
            details: [
                "next_job_id": AnySendable(analyzeJob.id),
                "next_job_type": AnySendable(analyzeJob.type.rawValue)
            ],
            createdAt: now
        )
        return metadata.toJSONString()
    }

    private func executeAudioAnalyze(job: PipelineJob, now: Date) async throws -> String {
        let payload = try decodeAudioAnalyzePayload(from: job.payloadJSON)
        let fileURL = try resolveLocalFileURL(from: payload.sourceURI)
        let filePath = fileURL.path
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: filePath) else {
            throw PipelineRuntimeError.sourceNotFound(payload.sourceURI)
        }

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)

        let segmentCount: Int
        if durationSeconds.isFinite, durationSeconds > 0 {
            segmentCount = max(1, Int(ceil(durationSeconds / 2.0)))
        } else {
            segmentCount = 0
        }

        let analysis = AudioAnalyzeResult(
            sourceType: payload.sourceType,
            sourceURI: payload.sourceURI,
            requestedBy: payload.requestedBy,
            analyzedAt: now,
            durationSeconds: durationSeconds.isFinite ? durationSeconds : nil,
            audioTrackCount: tracks.count,
            estimatedSegmentCount: segmentCount,
            note: "Placeholder audio analysis completed. Ready for chart-generation handoff."
        )

        let artifact = ArtifactRecord(
            workflowID: job.workflowID,
            jobID: job.id,
            artifactType: "audio_analysis",
            uri: fileURL.absoluteString,
            contentType: "application/json",
            checksum: nil,
            metadataJSON: analysis.toJSONString(),
            createdAt: now
        )
        try await artifacts.insert(artifact)
        try await appendEvent(
            workflowID: job.workflowID,
            jobID: job.id,
            eventType: "audio_analysis_completed",
            message: "Audio analysis placeholder completed",
            details: [
                "estimated_segment_count": AnySendable(analysis.estimatedSegmentCount),
                "audio_track_count": AnySendable(analysis.audioTrackCount),
                "duration_seconds": AnySendable(analysis.durationSeconds ?? 0)
            ],
            createdAt: now
        )
        return analysis.toJSONString()
    }

    private func enqueueAudioAnalyzeFollowUp(for job: PipelineJob, payload: AudioIngestPayload, createdAt: Date) async throws -> PipelineJob {
        let useCase = SubmitAudioAnalyzeJob(jobs: jobs)
        let analyzeJob = try await useCase.execute(
            EnqueueAudioAnalyzeRequest(
                workflowID: job.workflowID,
                sourceURI: payload.sourceURI,
                sourceType: payload.sourceType,
                requestedBy: payload.requestedBy
            )
        )
        try await appendEvent(
            workflowID: job.workflowID,
            jobID: analyzeJob.id,
            eventType: "job_enqueued",
            message: "Audio analyze job enqueued",
            details: [
                "source_uri": AnySendable(payload.sourceURI),
                "source_type": AnySendable(payload.sourceType),
                "requested_by": AnySendable(payload.requestedBy),
                "trigger_job_id": AnySendable(job.id)
            ],
            createdAt: createdAt
        )
        return analyzeJob
    }

    private func decodeAudioIngestPayload(from json: String) throws -> AudioIngestPayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AudioIngestPayload.self, from: data)
    }

    private func decodeAudioAnalyzePayload(from json: String) throws -> AudioAnalyzePayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AudioAnalyzePayload.self, from: data)
    }

    private func resolveLocalFileURL(from sourceURI: String) throws -> URL {
        if sourceURI.hasPrefix("file://"), let url = URL(string: sourceURI), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: sourceURI)
    }

    private func appendEvent(workflowID: String, jobID: String?, eventType: String, message: String?, details: [String: AnySendable], createdAt: Date) async throws {
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
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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

    private static func sampleRate(from formatDescriptions: [Any]?) -> Double? {
        guard let descriptions = formatDescriptions else { return nil }
        for case let description as CMFormatDescription in descriptions {
            if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                return stream.mSampleRate
            }
        }
        return nil
    }

    private static func channelCount(from formatDescriptions: [Any]?) -> Int? {
        guard let descriptions = formatDescriptions else { return nil }
        for case let description as CMFormatDescription in descriptions {
            if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                return Int(stream.mChannelsPerFrame)
            }
        }
        return nil
    }

    private static func contentType(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "aiff", "aif": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default: return nil
        }
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
      enqueue-audio-ingest --source-uri <uri> [--source-type file] [--requested-by cli] [--idempotency-key <key>]
      list-jobs [--status queued|running|failed|succeeded|cancelled]
      show-job <job-id>
      list-events [--workflow-id <workflow-id>] [--job-id <job-id>] [--limit <count>]
      list-artifacts [--workflow-id <workflow-id>] [--job-id <job-id>] [--limit <count>]

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
        case "enqueue-audio-ingest", "enqueue-chart-ingest":
            return .enqueueAudioIngest(
                sourceURI: value(for: "--source-uri", in: args) ?? "",
                sourceType: value(for: "--source-type", in: args) ?? "file",
                requestedBy: value(for: "--requested-by", in: args) ?? "cli",
                idempotencyKey: value(for: "--idempotency-key", in: args)
            )
        case "list-jobs":
            return .listJobs(status: value(for: "--status", in: args).flatMap(PipelineJobStatus.init(rawValue:)))
        case "show-job":
            return args.count >= 2 ? .showJob(id: args[1]) : .help
        case "list-events":
            return .listEvents(
                workflowID: value(for: "--workflow-id", in: args),
                jobID: value(for: "--job-id", in: args),
                limit: intValue(for: "--limit", in: args) ?? 50
            )
        case "list-artifacts":
            return .listArtifacts(
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

public struct AudioIngestResult: Codable, Sendable {
    public let sourceType: String
    public let sourceURI: String
    public let requestedBy: String
    public let filePath: String
    public let fileSizeBytes: Int
    public let contentType: String?
    public let durationSeconds: Double?
    public let audioTrackCount: Int
    public let sampleRate: Double?
    public let channelCount: Int?
    public let modifiedAt: Date?
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

public struct AudioAnalyzeResult: Codable, Sendable {
    public let sourceType: String
    public let sourceURI: String
    public let requestedBy: String
    public let analyzedAt: Date
    public let durationSeconds: Double?
    public let audioTrackCount: Int
    public let estimatedSegmentCount: Int
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
    public init(_ value: Any) { self.value = value }
}

private final class WorkerSignalMonitor: @unchecked Sendable {
    static let shared = WorkerSignalMonitor()
    private let lock = NSLock()
    private var stopRequested = false

    var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    func requestStop() {
        lock.lock(); stopRequested = true; lock.unlock()
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
