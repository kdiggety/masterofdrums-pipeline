import Foundation
import AVFoundation
import CryptoKit
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
    case validateAudioAnalyzer(sourceURI: String, sourceType: String, requestedBy: String, outputPath: String?)
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
    private let audioAnalyzerConfiguration: AudioAnalyzerConfiguration

    public init(
        configuration: SQLiteConfiguration = .fromEnvironment(),
        audioAnalyzerConfiguration: AudioAnalyzerConfiguration = .fromEnvironment()
    ) {
        let database = SQLiteDatabase(configuration: configuration)
        self.database = database
        self.migrator = SQLiteMigrator(database: database)
        self.workflows = SQLiteWorkflowStore(database: database)
        self.events = SQLiteWorkflowEventStore(database: database)
        self.artifacts = SQLiteArtifactStore(database: database)
        self.jobs = SQLiteJobStore(database: database)
        self.audioAnalyzerConfiguration = audioAnalyzerConfiguration
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

        case .validateAudioAnalyzer(let sourceURI, let sourceType, let requestedBy, let outputPath):
            let analysis = try validateAudioAnalyzer(sourceURI: sourceURI, sourceType: sourceType, requestedBy: requestedBy, outputPath: outputPath)
            print(analysis.toJSONString())

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
        case .chartGenerate:
            return try await executeChartGenerate(job: job, now: now)
        case .chartValidate, .chartExport:
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

        let analyzer = audioAnalyzerConfiguration
        guard analyzer.isEnabled else {
            throw PipelineRuntimeError.audioAnalyzerNotConfigured
        }

        let outputURL = try prepareArtifactOutputURL(workflowID: job.workflowID, jobID: job.id, createdAt: now)
        let rawAnalysis = try runAudioAnalyzer(
            analyzer,
            workflowID: job.workflowID,
            jobID: job.id,
            sourceURL: fileURL,
            outputURL: outputURL,
            payload: payload,
            analyzedAt: now
        )
        let analysis = AudioAnalysisContract(
            schemaVersion: rawAnalysis.schemaVersion,
            source: rawAnalysis.source,
            analysis: AudioAnalysisSummary(
                analyzedAt: rawAnalysis.analysis.analyzedAt,
                durationSeconds: rawAnalysis.analysis.durationSeconds,
                audioTrackCount: rawAnalysis.analysis.audioTrackCount,
                estimatedSegmentCount: rawAnalysis.analysis.estimatedSegmentCount,
                estimatedTempoBPM: rawAnalysis.analysis.estimatedTempoBPM,
                downbeatOffsetSeconds: rawAnalysis.analysis.downbeatOffsetSeconds,
                confidence: rawAnalysis.analysis.confidence,
                artifactURI: outputURL.absoluteString,
                analyzerCommand: analyzer.commandTemplate
            ),
            segments: rawAnalysis.segments,
            warnings: rawAnalysis.warnings,
            note: rawAnalysis.note,
            rawAnalyzerOutput: rawAnalysis.rawAnalyzerOutput
        )
        try analysis.write(to: outputURL)

        let artifact = ArtifactRecord(
            workflowID: job.workflowID,
            jobID: job.id,
            artifactType: "audio_analysis",
            uri: outputURL.absoluteString,
            contentType: "application/json",
            checksum: try Self.sha256Hex(for: outputURL),
            metadataJSON: analysis.analysis.toJSONString(),
            createdAt: now
        )
        try await artifacts.insert(artifact)
        try await appendEvent(
            workflowID: job.workflowID,
            jobID: job.id,
            eventType: "audio_analysis_completed",
            message: "Audio analysis completed and persisted",
            details: [
                "artifact_uri": AnySendable(outputURL.absoluteString),
                "schema_version": AnySendable(analysis.schemaVersion),
                "segment_count": AnySendable(analysis.analysis.estimatedSegmentCount),
                "duration_seconds": AnySendable(analysis.analysis.durationSeconds ?? 0),
                "analyzer_command": AnySendable(analyzer.commandTemplate)
            ],
            createdAt: now
        )

        let chartGenerateJob = try await enqueueChartGenerateFollowUp(
            for: job,
            payload: payload,
            audioAnalysisArtifactURI: outputURL.absoluteString,
            createdAt: now
        )
        try await appendEvent(
            workflowID: job.workflowID,
            jobID: job.id,
            eventType: "chart_generate_enqueued",
            message: "Enqueued follow-up chart_generate job \(chartGenerateJob.id)",
            details: [
                "next_job_id": AnySendable(chartGenerateJob.id),
                "next_job_type": AnySendable(chartGenerateJob.type.rawValue),
                "audio_analysis_artifact_uri": AnySendable(outputURL.absoluteString)
            ],
            createdAt: now
        )
        return analysis.toJSONString()
    }

    public func validateAudioAnalyzer(sourceURI: String, sourceType: String = "file", requestedBy: String = "cli", outputPath: String? = nil) throws -> AudioAnalysisContract {
        let payload = AudioAnalyzePayload(sourceType: sourceType, sourceURI: sourceURI, requestedBy: requestedBy)
        let sourceURL = try resolveLocalFileURL(from: sourceURI)
        let filePath = sourceURL.path
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw PipelineRuntimeError.sourceNotFound(sourceURI)
        }

        let analyzer = audioAnalyzerConfiguration
        guard analyzer.isEnabled else {
            throw PipelineRuntimeError.audioAnalyzerNotConfigured
        }

        let outputURL: URL
        if let outputPath, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputURL = URL(fileURLWithPath: outputPath)
            if let directory = outputURL.deletingLastPathComponent() as URL? {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } else {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("masterofdrums-pipeline", isDirectory: true)
                .appendingPathComponent("analyzer-validation", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            outputURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).json")
        }

        let analysis = try runAudioAnalyzer(
            analyzer,
            workflowID: "analyzer-validation",
            jobID: UUID().uuidString,
            sourceURL: sourceURL,
            outputURL: outputURL,
            payload: payload,
            analyzedAt: Date()
        )
        let persisted = AudioAnalysisContract(
            schemaVersion: analysis.schemaVersion,
            source: analysis.source,
            analysis: AudioAnalysisSummary(
                analyzedAt: analysis.analysis.analyzedAt,
                durationSeconds: analysis.analysis.durationSeconds,
                audioTrackCount: analysis.analysis.audioTrackCount,
                estimatedSegmentCount: analysis.analysis.estimatedSegmentCount,
                estimatedTempoBPM: analysis.analysis.estimatedTempoBPM,
                downbeatOffsetSeconds: analysis.analysis.downbeatOffsetSeconds,
                confidence: analysis.analysis.confidence,
                artifactURI: outputURL.absoluteString,
                analyzerCommand: analyzer.commandTemplate
            ),
            segments: analysis.segments,
            warnings: analysis.warnings,
            note: analysis.note,
            rawAnalyzerOutput: analysis.rawAnalyzerOutput
        )
        try persisted.write(to: outputURL)
        fputs("[pipeline] analyzer validation artifact: \(outputURL.path)\n", stderr)
        return persisted
    }

    private func executeChartGenerate(job: PipelineJob, now: Date) async throws -> String {
        let payload = try decodeChartGeneratePayload(from: job.payloadJSON)
        let analysisURL = try resolveLocalFileURL(from: payload.audioAnalysisArtifactURI)
        let data = try Data(contentsOf: analysisURL)
        let audioAnalysis = try JSONDecoder.pipeline.decode(AudioAnalysisContract.self, from: data)

        let normalizedOutputURL = try prepareArtifactOutputURL(category: "normalized-analysis", workflowID: job.workflowID, jobID: job.id, createdAt: now)
        let baseChartOutputURL = try prepareArtifactOutputURL(category: "base-chart", workflowID: job.workflowID, jobID: job.id, createdAt: now)

        let generated = ChartGenerator.generate(from: audioAnalysis, generatedAt: now, normalizedAnalysisArtifactURI: normalizedOutputURL.absoluteString)
        try generated.normalized.write(to: normalizedOutputURL)
        try generated.baseChart.write(to: baseChartOutputURL)

        try await artifacts.insert(
            ArtifactRecord(
                workflowID: job.workflowID,
                jobID: job.id,
                artifactType: "normalized_analysis",
                uri: normalizedOutputURL.absoluteString,
                contentType: "application/json",
                checksum: try Self.sha256Hex(for: normalizedOutputURL),
                metadataJSON: generated.normalized.summary.toJSONString(),
                createdAt: now
            )
        )
        try await artifacts.insert(
            ArtifactRecord(
                workflowID: job.workflowID,
                jobID: job.id,
                artifactType: "base_chart",
                uri: baseChartOutputURL.absoluteString,
                contentType: "application/json",
                checksum: try Self.sha256Hex(for: baseChartOutputURL),
                metadataJSON: Self.baseChartMetadataJSON(from: generated.baseChart),
                createdAt: now
            )
        )

        try await appendEvent(
            workflowID: job.workflowID,
            jobID: job.id,
            eventType: "normalized_analysis_created",
            message: "Normalized analysis artifact persisted",
            details: [
                "artifact_uri": AnySendable(normalizedOutputURL.absoluteString),
                "beat_count": AnySendable(generated.normalized.summary.beatCount),
                "bar_count": AnySendable(generated.normalized.summary.barCount),
                "drum_event_count": AnySendable(generated.normalized.summary.drumEventCount)
            ],
            createdAt: now
        )
        try await appendEvent(
            workflowID: job.workflowID,
            jobID: job.id,
            eventType: "base_chart_created",
            message: "Base chart artifact persisted",
            details: [
                "artifact_uri": AnySendable(baseChartOutputURL.absoluteString),
                "measure_count": AnySendable(generated.baseChart.chart.measures.count),
                "note_count": AnySendable(generated.baseChart.chart.notes.count),
                "lane_count": AnySendable(generated.baseChart.chart.lanes.count)
            ],
            createdAt: now
        )
        return generated.baseChart.toJSONString()
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

    private func enqueueChartGenerateFollowUp(for job: PipelineJob, payload: AudioAnalyzePayload, audioAnalysisArtifactURI: String, createdAt: Date) async throws -> PipelineJob {
        let useCase = SubmitChartGenerateJob(jobs: jobs)
        let chartGenerateJob = try await useCase.execute(
            EnqueueChartGenerateRequest(
                workflowID: job.workflowID,
                sourceURI: payload.sourceURI,
                sourceType: payload.sourceType,
                requestedBy: payload.requestedBy,
                audioAnalysisArtifactURI: audioAnalysisArtifactURI
            )
        )
        try await appendEvent(
            workflowID: job.workflowID,
            jobID: chartGenerateJob.id,
            eventType: "job_enqueued",
            message: "Chart generate job enqueued",
            details: [
                "source_uri": AnySendable(payload.sourceURI),
                "source_type": AnySendable(payload.sourceType),
                "requested_by": AnySendable(payload.requestedBy),
                "audio_analysis_artifact_uri": AnySendable(audioAnalysisArtifactURI),
                "trigger_job_id": AnySendable(job.id)
            ],
            createdAt: createdAt
        )
        return chartGenerateJob
    }

    private func decodeAudioIngestPayload(from json: String) throws -> AudioIngestPayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AudioIngestPayload.self, from: data)
    }

    private func decodeAudioAnalyzePayload(from json: String) throws -> AudioAnalyzePayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AudioAnalyzePayload.self, from: data)
    }

    private func decodeChartGeneratePayload(from json: String) throws -> ChartGeneratePayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ChartGeneratePayload.self, from: data)
    }

    private func resolveLocalFileURL(from sourceURI: String) throws -> URL {
        if sourceURI.hasPrefix("file://"), let url = URL(string: sourceURI), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: sourceURI)
    }

    private func prepareArtifactOutputURL(workflowID: String, jobID: String, createdAt: Date) throws -> URL {
        try prepareArtifactOutputURL(category: "audio-analysis", workflowID: workflowID, jobID: jobID, createdAt: createdAt)
    }

    private func prepareArtifactOutputURL(category: String, workflowID: String, jobID: String, createdAt: Date) throws -> URL {
        let rootURL = URL(fileURLWithPath: database.configuration.artifactRoot, isDirectory: true)
        let directoryURL = rootURL
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(workflowID, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let stamp = Self.filenameTimestamp(createdAt)
        return directoryURL.appendingPathComponent("\(stamp)-\(jobID).json")
    }

    private func runAudioAnalyzer(
        _ configuration: AudioAnalyzerConfiguration,
        workflowID: String,
        jobID: String,
        sourceURL: URL,
        outputURL: URL,
        payload: AudioAnalyzePayload,
        analyzedAt: Date
    ) throws -> AudioAnalysisContract {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", configuration.renderCommand(inputPath: sourceURL.path, outputPath: outputURL.path)]
        process.environment = configuration.processEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            workflowID: workflowID,
            jobID: jobID,
            inputPath: sourceURL.path,
            outputPath: outputURL.path,
            sourceType: payload.sourceType,
            sourceURI: payload.sourceURI,
            requestedBy: payload.requestedBy
        )

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        if let timeout = configuration.timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    throw PipelineRuntimeError.audioAnalyzerTimedOut(timeout)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        } else {
            process.waitUntilExit()
        }

        let stdoutText = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw PipelineRuntimeError.audioAnalyzerFailed(Self.describeAnalyzerFailure(status: process.terminationStatus, stderrText: stderrText, stdoutText: stdoutText))
        }

        let outputData: Data
        if FileManager.default.fileExists(atPath: outputURL.path) {
            outputData = try Data(contentsOf: outputURL)
        } else if configuration.acceptsStdoutJSON, let stdoutData = stdoutText.data(using: .utf8), Self.looksLikeJSON(stdoutText) {
            try stdoutData.write(to: outputURL, options: .atomic)
            outputData = stdoutData
        } else {
            throw PipelineRuntimeError.audioAnalyzerFailed(Self.missingAnalyzerOutputMessage(outputPath: outputURL.path, stdoutText: stdoutText, stderrText: stderrText, acceptsStdoutJSON: configuration.acceptsStdoutJSON))
        }

        if let decoded = try? JSONDecoder.pipeline.decode(AudioAnalysisContract.self, from: outputData) {
            return decoded
        }

        let rawObject = try JSONSerialization.jsonObject(with: outputData)
        let normalized = AudioAnalysisContract.fromAnalyzerOutput(
            rawObject,
            sourceType: payload.sourceType,
            sourceURI: payload.sourceURI,
            requestedBy: payload.requestedBy,
            analyzedAt: analyzedAt,
            commandTemplate: configuration.commandTemplate
        )
        try normalized.write(to: outputURL)
        return normalized
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

    private static func baseChartMetadataJSON(from chart: BaseChartContract) -> String {
        struct BaseChartMetadata: Encodable {
            let difficulty: String
            let ticksPerBeat: Int
            let measureCount: Int
            let noteCount: Int
            let laneCount: Int
        }
        let metadata = BaseChartMetadata(
            difficulty: chart.chart.difficulty,
            ticksPerBeat: chart.chart.ticksPerBeat,
            measureCount: chart.chart.measures.count,
            noteCount: chart.chart.notes.count,
            laneCount: chart.chart.lanes.count
        )
        guard let data = try? JSONEncoder.pipeline.encode(metadata) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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

    private static func placeholderSegments(durationSeconds: Double?, segmentCount: Int) -> [AudioAnalysisSegment] {
        guard let durationSeconds, durationSeconds > 0, segmentCount > 0 else { return [] }
        let segmentLength = durationSeconds / Double(segmentCount)
        return (0..<segmentCount).map { index in
            let start = Double(index) * segmentLength
            let end = min(durationSeconds, Double(index + 1) * segmentLength)
            return AudioAnalysisSegment(
                index: index,
                startSeconds: start,
                endSeconds: end,
                label: "section_\(index + 1)",
                confidence: nil
            )
        }
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

    private static func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first == "{" || first == "["
    }

    private static func describeAnalyzerFailure(status: Int32, stderrText: String, stdoutText: String) -> String {
        var parts: [String] = ["analyzer exited with status \(status)"]
        if !stderrText.isEmpty {
            parts.append("stderr: \(stderrText)")
        }
        if !stdoutText.isEmpty && !looksLikeJSON(stdoutText) {
            parts.append("stdout: \(stdoutText)")
        }
        return parts.joined(separator: " | ")
    }

    private static func missingAnalyzerOutputMessage(outputPath: String, stdoutText: String, stderrText: String, acceptsStdoutJSON: Bool) -> String {
        var parts: [String] = ["analyzer did not write output file: \(outputPath)"]
        if acceptsStdoutJSON {
            parts.append("stdout fallback was enabled but stdout did not contain JSON")
        }
        if !stderrText.isEmpty {
            parts.append("stderr: \(stderrText)")
        }
        if !stdoutText.isEmpty {
            parts.append("stdout: \(stdoutText)")
        }
        return parts.joined(separator: " | ")
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        artifactFilenameFormatter.string(from: date)
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
    private static let artifactFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()

    public static let helpText = """
    MasterOfDrums Pipeline

    Commands:
      init-db
      worker [--stop-after-idle-polls <count>]
      enqueue-audio-ingest --source-uri <uri> [--source-type file] [--requested-by cli] [--idempotency-key <key>]
      validate-audio-analyzer --source-uri <uri> [--source-type file] [--requested-by cli] [--output-path <path>]
      list-jobs [--status queued|running|failed|succeeded|cancelled]
      show-job <job-id>
      list-events [--workflow-id <workflow-id>] [--job-id <job-id>] [--limit <count>]
      list-artifacts [--workflow-id <workflow-id>] [--job-id <job-id>] [--limit <count>]

    Worker environment:
      PIPELINE_WORKER_POLL_INTERVAL_SECONDS    Seconds to wait between empty polls (default: 1)
      PIPELINE_ARTIFACT_ROOT                   Root directory for persisted analysis artifacts
      PIPELINE_AUDIO_ANALYZER_COMMAND          Shell command template with {input} and {output} placeholders
      PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS  Optional analyzer timeout in seconds
      PIPELINE_AUDIO_ANALYZER_STDOUT_JSON      Accept analyzer JSON from stdout when {output} is not written (default: false)
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
        case "validate-audio-analyzer":
            return .validateAudioAnalyzer(
                sourceURI: value(for: "--source-uri", in: args) ?? "",
                sourceType: value(for: "--source-type", in: args) ?? "file",
                requestedBy: value(for: "--requested-by", in: args) ?? "cli",
                outputPath: value(for: "--output-path", in: args)
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
    case audioAnalyzerNotConfigured
    case audioAnalyzerTimedOut(TimeInterval)
    case audioAnalyzerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let sourceURI):
            return "Source file not found: \(sourceURI)"
        case .unsupportedJobType(let type):
            return "Unsupported job type: \(type)"
        case .audioAnalyzerNotConfigured:
            return "Audio analyzer is not configured. Set PIPELINE_AUDIO_ANALYZER_COMMAND with {input} and {output} placeholders."
        case .audioAnalyzerTimedOut(let timeout):
            return "Audio analyzer timed out after \(timeout) seconds"
        case .audioAnalyzerFailed(let message):
            return "Audio analyzer failed: \(message)"
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
        let encoder = JSONEncoder.pipeline
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct AudioAnalyzerConfiguration: Sendable {
    public let commandTemplate: String
    public let timeoutSeconds: TimeInterval?
    public let acceptsStdoutJSON: Bool

    public var isEnabled: Bool {
        let trimmed = commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.contains("{input}") && trimmed.contains("{output}")
    }

    public static func fromEnvironment(_ environment: [String: String]? = nil) -> AudioAnalyzerConfiguration {
        let resolved = environment ?? Self.liveEnvironment()
        return AudioAnalyzerConfiguration(
            commandTemplate: resolved["PIPELINE_AUDIO_ANALYZER_COMMAND"] ?? "",
            timeoutSeconds: resolved["PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS"].flatMap(TimeInterval.init),
            acceptsStdoutJSON: Self.boolFlag(resolved["PIPELINE_AUDIO_ANALYZER_STDOUT_JSON"])
        )
    }

    public func renderCommand(inputPath: String, outputPath: String) -> String {
        commandTemplate
            .replacingOccurrences(of: "{input}", with: Self.shellEscape(inputPath))
            .replacingOccurrences(of: "{output}", with: Self.shellEscape(outputPath))
    }

    public func processEnvironment(
        inherited: [String: String],
        workflowID: String,
        jobID: String,
        inputPath: String,
        outputPath: String,
        sourceType: String,
        sourceURI: String,
        requestedBy: String
    ) -> [String: String] {
        var environment = inherited
        environment["PIPELINE_ANALYZER_INPUT_PATH"] = inputPath
        environment["PIPELINE_ANALYZER_OUTPUT_PATH"] = outputPath
        environment["PIPELINE_ANALYZER_WORKFLOW_ID"] = workflowID
        environment["PIPELINE_ANALYZER_JOB_ID"] = jobID
        environment["PIPELINE_ANALYZER_SOURCE_TYPE"] = sourceType
        environment["PIPELINE_ANALYZER_SOURCE_URI"] = sourceURI
        environment["PIPELINE_ANALYZER_REQUESTED_BY"] = requestedBy
        environment["PIPELINE_ANALYZER_CONTRACT_SCHEMA_URI"] = AudioAnalysisContract.schemaURI
        environment["PIPELINE_ANALYZER_CONTRACT_SCHEMA_VERSION"] = AudioAnalysisContract.schemaVersion
        return environment
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func liveEnvironment() -> [String: String] {
        [
            "PIPELINE_AUDIO_ANALYZER_COMMAND": getenvString("PIPELINE_AUDIO_ANALYZER_COMMAND"),
            "PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS": getenvString("PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS"),
            "PIPELINE_AUDIO_ANALYZER_STDOUT_JSON": getenvString("PIPELINE_AUDIO_ANALYZER_STDOUT_JSON")
        ].compactMapValues { $0 }
    }

    private static func getenvString(_ key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        return String(cString: raw)
    }

    private static func boolFlag(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }
}

extension JSONDecoder {
    static var pipeline: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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
