import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import PipelineRuntime
import PipelineApplication
import PipelineDomain
import PipelineInfrastructure

final class PipelineRuntimeFixtureTests: XCTestCase {
    func testWorkerProcessesKnownWAVFixtureThroughAnalyzeStage() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "known-tone", withExtension: "wav", subdirectory: "Fixtures"))
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("masterofdrums-pipeline-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let databasePath = tempRoot.appendingPathComponent("pipeline.sqlite").path
        let artifactRoot = tempRoot.appendingPathComponent("artifacts", isDirectory: true).path
        let runtime = PipelineRuntime(
            configuration: SQLiteConfiguration(
                databasePath: databasePath,
                artifactRoot: artifactRoot,
                autoMigrate: true
            )
        )

        let analyzerCommand = #"""
        cat > {output} <<'JSON'
        {"analysis":{"audioTrackCount":1,"confidence":0.99,"downbeatOffsetSeconds":0.0,"durationSeconds":1.0,"estimatedSegmentCount":1,"estimatedTempoBPM":120.0},"note":"fixture analyzer output","segments":[{"confidence":0.99,"endSeconds":1.0,"index":0,"label":"full_track","startSeconds":0.0}],"warnings":[]}
        JSON
        """#
        setenv("PIPELINE_AUDIO_ANALYZER_COMMAND", analyzerCommand, 1)
        defer { unsetenv("PIPELINE_AUDIO_ANALYZER_COMMAND") }

        try await runtime.run(
            command: .enqueueAudioIngest(
                sourceURI: fixtureURL.absoluteString,
                sourceType: "file",
                requestedBy: "test",
                idempotencyKey: nil
            )
        )
        try await runtime.run(command: .worker(stopAfterIdlePolls: 1))

        let jobs = try await runtime.jobs.list(status: nil)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertTrue(jobs.allSatisfy { $0.status == .succeeded }, "expected ingest and analyze jobs to succeed")

        let ingestJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioIngest }))
        let analyzeJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioAnalyze }))
        XCTAssertEqual(ingestJob.workflowID, analyzeJob.workflowID)

        let artifacts = try await runtime.artifacts.list(workflowID: ingestJob.workflowID, jobID: nil, limit: 10)
        XCTAssertEqual(Set(artifacts.map(\.artifactType)), ["source_audio", "audio_analysis"])

        let sourceArtifact = try XCTUnwrap(artifacts.first(where: { $0.artifactType == "source_audio" }))
        XCTAssertEqual(sourceArtifact.uri, fixtureURL.absoluteString)
        XCTAssertEqual(sourceArtifact.contentType, "audio/wav")

        let analysisArtifact = try XCTUnwrap(artifacts.first(where: { $0.artifactType == "audio_analysis" }))
        XCTAssertEqual(analysisArtifact.contentType, "application/json")
        XCTAssertTrue(analysisArtifact.uri.hasPrefix("file://"))
        XCTAssertNotEqual(analysisArtifact.uri, fixtureURL.absoluteString)

        let ingestResult = try decode(AudioIngestResult.self, from: ingestJob.resultJSON)
        XCTAssertEqual(ingestResult.filePath, fixtureURL.path)
        XCTAssertEqual(ingestResult.contentType, "audio/wav")
        XCTAssertEqual(ingestResult.audioTrackCount, 1)
        XCTAssertEqual(ingestResult.channelCount, 1)
        XCTAssertEqual(try XCTUnwrap(ingestResult.sampleRate), 44_100, accuracy: 1)
        XCTAssertEqual(ingestResult.fileSizeBytes, fileSize(at: fixtureURL))
        XCTAssertGreaterThan(ingestResult.durationSeconds ?? 0, 0.9)
        XCTAssertLessThan(ingestResult.durationSeconds ?? 0, 1.1)

        let analysisResult = try decode(AudioAnalysisContract.self, from: analyzeJob.resultJSON)
        XCTAssertEqual(analysisResult.schemaVersion, AudioAnalysisContract.schemaVersion)
        XCTAssertEqual(analysisResult.schemaURI, AudioAnalysisContract.schemaURI)
        XCTAssertEqual(analysisResult.analysisStage, "audio_analysis_mvp")
        XCTAssertEqual(analysisResult.source.sourceURI, fixtureURL.absoluteString)
        XCTAssertEqual(analysisResult.source.sourceType, "file")
        XCTAssertEqual(analysisResult.source.requestedBy, "test")
        XCTAssertEqual(analysisResult.analysis.audioTrackCount, 1)
        XCTAssertEqual(analysisResult.analysis.estimatedSegmentCount, 1)
        XCTAssertEqual(try XCTUnwrap(analysisResult.analysis.estimatedTempoBPM), 120.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(analysisResult.analysis.confidence), 0.99, accuracy: 0.001)
        XCTAssertEqual(analysisResult.analysis.artifactURI, analysisArtifact.uri)
        XCTAssertEqual(analysisResult.analysis.analyzerCommand, analyzerCommand)
        XCTAssertEqual(analysisResult.segments.count, 1)
        XCTAssertEqual(analysisResult.segments.first?.label, "full_track")

        let analysisArtifactURL = try XCTUnwrap(URL(string: analysisArtifact.uri))
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysisArtifactURL.path))
        let persistedAnalysis = try decode(AudioAnalysisContract.self, from: String(decoding: Data(contentsOf: analysisArtifactURL), as: UTF8.self))
        XCTAssertEqual(persistedAnalysis.analysis.artifactURI, analysisArtifact.uri)
        XCTAssertEqual(persistedAnalysis.segments.count, 1)
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String?) throws -> T {
        let jsonString = try XCTUnwrap(json)
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let decoder = JSONDecoder.pipeline
        return try decoder.decode(type, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        let decoder = JSONDecoder.pipeline
        return try decoder.decode(type, from: data)
    }

    private func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}
