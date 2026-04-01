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
    func testWorkerProcessesKnownWAVFixtureThroughChartGenerationStage() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "known-tone", withExtension: "wav"))
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("masterofdrums-pipeline-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let databasePath = tempRoot.appendingPathComponent("pipeline.sqlite").path
        let artifactRoot = tempRoot.appendingPathComponent("artifacts", isDirectory: true).path

        let analyzerCommand = #"""
        test -f {input} >/dev/null
        cat > {output} <<'JSON'
        {"analysis":{"audioTrackCount":1,"confidence":0.99,"downbeatOffsetSeconds":0.0,"durationSeconds":1.0,"estimatedSegmentCount":1,"estimatedTempoBPM":120.0},"beats":[0.0,0.5,1.0],"drumEvents":[{"confidence":0.9,"eventID":"kick-1","label":"kick","onsetSeconds":0.0,"velocity":1.0},{"confidence":0.8,"eventID":"snare-1","label":"snare","onsetSeconds":0.5,"velocity":0.7}],"note":"fixture analyzer output","segments":[{"confidence":0.99,"endSeconds":1.0,"index":0,"label":"full_track","startSeconds":0.0}],"warnings":[]}
        JSON
        """#
        let runtime = makeRuntime(databasePath: databasePath, artifactRoot: artifactRoot, analyzerCommand: analyzerCommand)

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
        XCTAssertEqual(jobs.count, 3)
        XCTAssertTrue(jobs.allSatisfy { $0.status == .succeeded }, "expected ingest, analyze, and chart generate jobs to succeed")

        let ingestJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioIngest }))
        let analyzeJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioAnalyze }))
        let chartGenerateJob = try XCTUnwrap(jobs.first(where: { $0.type == .chartGenerate }))
        XCTAssertEqual(ingestJob.workflowID, analyzeJob.workflowID)
        XCTAssertEqual(analyzeJob.workflowID, chartGenerateJob.workflowID)

        let artifacts = try await runtime.artifacts.list(workflowID: ingestJob.workflowID, jobID: nil, limit: 10)
        XCTAssertEqual(Set(artifacts.map(\.artifactType)), ["source_audio", "audio_analysis", "normalized_analysis", "base_chart"])

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

        let normalizedArtifact = try XCTUnwrap(artifacts.first(where: { $0.artifactType == "normalized_analysis" }))
        let normalizedArtifactURL = try XCTUnwrap(URL(string: normalizedArtifact.uri))
        let persistedNormalized = try decode(NormalizedAnalysisContract.self, from: String(decoding: Data(contentsOf: normalizedArtifactURL), as: UTF8.self))
        XCTAssertEqual(persistedNormalized.source.audioAnalysisArtifactURI, analysisArtifact.uri)
        XCTAssertEqual(persistedNormalized.summary.beatCount, 3)
        XCTAssertEqual(persistedNormalized.summary.barCount, 1)
        XCTAssertEqual(persistedNormalized.drumEvents.count, 2)
        XCTAssertEqual(try XCTUnwrap(persistedNormalized.beatGrid.first?.startSeconds), 0.0, accuracy: 0.001)

        let baseChartArtifact = try XCTUnwrap(artifacts.first(where: { $0.artifactType == "base_chart" }))
        let baseChartArtifactURL = try XCTUnwrap(URL(string: baseChartArtifact.uri))
        let persistedBaseChart = try decode(BaseChartContract.self, from: String(decoding: Data(contentsOf: baseChartArtifactURL), as: UTF8.self))
        XCTAssertEqual(persistedBaseChart.source.normalizedAnalysisArtifactURI, normalizedArtifact.uri)
        XCTAssertEqual(persistedBaseChart.chart.difficulty, "prototype")
        XCTAssertEqual(persistedBaseChart.chart.ticksPerBeat, 480)
        XCTAssertEqual(persistedBaseChart.chart.measures.count, 1)
        XCTAssertTrue(persistedBaseChart.chart.lanes.contains(.kick))
        XCTAssertTrue(persistedBaseChart.chart.lanes.contains(.snare))
        XCTAssertEqual(persistedBaseChart.chart.notes.count, 2)
    }

    func testGeneratedFixtureChartCanBeEvaluatedThroughCorpusRunner() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "known-tone", withExtension: "wav"))
        let corpusURL = try XCTUnwrap(Bundle.module.url(forResource: "chart-eval-corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(ChartEvaluationCorpus.self, from: Data(contentsOf: corpusURL))
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("masterofdrums-pipeline-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let analyzerCommand = #"""
        test -f {input} >/dev/null
        cat > {output} <<'JSON'
        {"analysis":{"audioTrackCount":1,"confidence":0.99,"downbeatOffsetSeconds":0.0,"durationSeconds":1.0,"estimatedSegmentCount":1,"estimatedTempoBPM":120.0},"beats":[0.0,0.5,1.0],"drumEvents":[{"confidence":0.9,"eventID":"kick-1","label":"kick","onsetSeconds":0.0,"velocity":1.0},{"confidence":0.8,"eventID":"snare-1","label":"snare","onsetSeconds":0.5,"velocity":0.7}],"note":"fixture analyzer output","segments":[{"confidence":0.99,"endSeconds":1.0,"index":0,"label":"full_track","startSeconds":0.0}],"warnings":[]}
        JSON
        """#
        let runtime = makeRuntime(
            databasePath: tempRoot.appendingPathComponent("pipeline.sqlite").path,
            artifactRoot: tempRoot.appendingPathComponent("artifacts", isDirectory: true).path,
            analyzerCommand: analyzerCommand
        )

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
        let ingestJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioIngest }))
        let artifacts = try await runtime.artifacts.list(workflowID: ingestJob.workflowID, jobID: nil, limit: 10)
        let baseChartArtifact = try XCTUnwrap(artifacts.first(where: { $0.artifactType == "base_chart" }))
        let baseChartArtifactURL = try XCTUnwrap(URL(string: baseChartArtifact.uri))
        let persistedBaseChart = try decode(BaseChartContract.self, from: String(decoding: Data(contentsOf: baseChartArtifactURL), as: UTF8.self))

        let corpusReport = ChartEvaluationRunner.evaluate(
            corpus: corpus,
            generatedCharts: ["known-tone": [persistedBaseChart.chart.difficulty: persistedBaseChart]],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertFalse(corpusReport.passed)
        XCTAssertEqual(corpusReport.totalExpectations, 2)
        XCTAssertEqual(corpusReport.passedExpectations, 1)
        XCTAssertEqual(corpusReport.failedExpectations, 1)
        XCTAssertEqual(corpusReport.missingCharts, ["known-tone:easy"])
        XCTAssertEqual(corpusReport.results.count, 1)

        let reportText = corpusReport.renderText()
        XCTAssertTrue(reportText.contains("corpus pass=1/2 failed=1 missing=1 tags=3"))
        XCTAssertTrue(reportText.contains("tag_summary"))
        XCTAssertTrue(reportText.contains("fixture"))
        XCTAssertTrue(reportText.contains("smoke"))
        XCTAssertTrue(reportText.contains("synthetic"))
        XCTAssertTrue(reportText.contains("known-tone [prototype] PASS"))
        XCTAssertTrue(reportText.contains("score=1.00"))
        XCTAssertTrue(reportText.contains("source=known-tone.wav"))
        XCTAssertTrue(reportText.contains("source_type=fixture_audio"))
        XCTAssertTrue(reportText.contains("review=synthetic_smoke"))
        XCTAssertTrue(reportText.contains("lane_usage"))
        XCTAssertTrue(reportText.contains("measure_density m0=2"))
        XCTAssertTrue(reportText.contains("kick=1"))
        XCTAssertTrue(reportText.contains("snare=1"))
        XCTAssertTrue(reportText.contains("note_preview"))
        XCTAssertTrue(reportText.contains("lane=kick") || reportText.contains("kick:vel="))
        XCTAssertTrue(reportText.contains("lane=snare") || reportText.contains("snare:vel="))
        XCTAssertTrue(reportText.contains("missing known-tone:easy"))
    }

    func testWorkerFallsBackToStdoutJSONWhenEnabled() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "known-tone", withExtension: "wav"))
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("masterofdrums-pipeline-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let analyzerCommand = #"""
        test -f {input} >/dev/null
        rm -f {output}
        printf '{"analysis":{"audioTrackCount":1,"durationSeconds":1.0,"estimatedSegmentCount":1,"estimatedTempoBPM":120.0},"warnings":["stdout-json"]}'
        """#
        let runtime = makeRuntime(
            databasePath: tempRoot.appendingPathComponent("pipeline.sqlite").path,
            artifactRoot: tempRoot.appendingPathComponent("artifacts", isDirectory: true).path,
            analyzerCommand: analyzerCommand,
            acceptsStdoutJSON: true
        )

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
        XCTAssertTrue(jobs.allSatisfy { $0.status == .succeeded })

        let analyzeJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioAnalyze }))
        let analysisResult = try decode(AudioAnalysisContract.self, from: analyzeJob.resultJSON)
        XCTAssertEqual(analysisResult.analysis.audioTrackCount, 1)
        XCTAssertEqual(analysisResult.warnings, ["stdout-json"])
    }

    func testWorkerPassesPipelineContextEnvironmentIntoAnalyzerProcess() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "known-tone", withExtension: "wav"))
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("masterofdrums-pipeline-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let analyzerCommand = #"""
        test -f {input} >/dev/null
        cat > {output} <<JSON
        {"analysis":{"audioTrackCount":1,"durationSeconds":1.0,"estimatedSegmentCount":1},"note":"'$PIPELINE_ANALYZER_WORKFLOW_ID|$PIPELINE_ANALYZER_JOB_ID|$PIPELINE_ANALYZER_REQUESTED_BY|$PIPELINE_ANALYZER_SOURCE_URI|$PIPELINE_ANALYZER_INPUT_PATH|$PIPELINE_ANALYZER_OUTPUT_PATH'"}
        JSON
        """#
        let runtime = makeRuntime(
            databasePath: tempRoot.appendingPathComponent("pipeline.sqlite").path,
            artifactRoot: tempRoot.appendingPathComponent("artifacts", isDirectory: true).path,
            analyzerCommand: analyzerCommand
        )

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
        let analyzeJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioAnalyze }))
        let analysisResult = try decode(AudioAnalysisContract.self, from: analyzeJob.resultJSON)
        let note = try XCTUnwrap(analysisResult.note)
        XCTAssertTrue(note.contains(analyzeJob.workflowID))
        XCTAssertTrue(note.contains(analyzeJob.id))
        XCTAssertTrue(note.contains("|test|"))
        XCTAssertTrue(note.contains(fixtureURL.absoluteString))
        XCTAssertTrue(note.contains(fixtureURL.path))
        XCTAssertTrue(note.contains(".json"))
    }

    func testWorkerNormalizesWrappedAnalyzerOutputWithDownbeatsAndMessyEventKeys() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "known-tone", withExtension: "wav"))
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("masterofdrums-pipeline-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let backendScript = tempRoot.appendingPathComponent("backend-analyzer.py")
        try #"""
import json
import os
import pathlib

output_path = pathlib.Path(os.environ["PIPELINE_ANALYZER_OUTPUT_PATH"])
payload = {
    "result": {
        "timing": {
            "beats": [{"time": 0.25}, {"time": 0.75}, {"time": 1.25}, {"time": 1.75}, {"time": 2.25}],
            "downbeats": [0.25, 2.25]
        },
        "drums": {
            "hits": [
                {"id": "evt-1", "time_seconds": 0.24, "instrument": "bass drum", "velocity": 0.98, "probability": 0.91},
                {"id": "evt-2", "time_seconds": 0.76, "class": "snare", "strength": 0.77, "score": 0.82},
                {"id": "evt-3", "start_seconds": 1.74, "type": "closed hi hat", "amplitude": 0.55, "confidence": 0.7}
            ]
        },
        "analysis": {
            "audioTrackCount": 1,
            "confidence": 0.95,
            "durationSeconds": 2.3,
            "estimatedSegmentCount": 1,
            "estimatedTempoBPM": 120.0,
            "note": "nested analysis note"
        },
        "segments": [
            {"segment_index": 0, "start": 0.0, "end": 2.3, "name": "full_track", "score": 0.97}
        ]
    },
    "warnings": ["backend-warning"],
    "runtime": {
        "warnings": ["runtime-warning"],
        "sourceType": os.environ.get("PIPELINE_ANALYZER_SOURCE_TYPE"),
        "schemaURI": os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_URI")
    }
}
output_path.write_text(json.dumps(payload), encoding="utf-8")
"""#.write(to: backendScript, atomically: true, encoding: .utf8)

        let wrapperPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("analyzer-wrapper.py")
            .path
        let analyzerCommand = "python3 \(shellQuote(wrapperPath)) --input {input} --output {output} --backend-command \(shellQuote("python3 \(backendScript.path)"))"
        let runtime = makeRuntime(
            databasePath: tempRoot.appendingPathComponent("pipeline.sqlite").path,
            artifactRoot: tempRoot.appendingPathComponent("artifacts", isDirectory: true).path,
            analyzerCommand: analyzerCommand
        )

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
        let ingestJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioIngest }))
        let artifacts = try await runtime.artifacts.list(workflowID: ingestJob.workflowID, jobID: nil, limit: 10)

        let analyzeJob = try XCTUnwrap(jobs.first(where: { $0.type == .audioAnalyze }))
        let analysisResult = try decode(AudioAnalysisContract.self, from: analyzeJob.resultJSON)
        XCTAssertEqual(analysisResult.analysis.audioTrackCount, 1)
        XCTAssertEqual(analysisResult.segments.first?.label, "full_track")
        XCTAssertEqual(analysisResult.note, "nested analysis note")
        XCTAssertTrue(analysisResult.warnings.contains("backend-warning"))
        XCTAssertTrue(analysisResult.warnings.contains("runtime-warning"))
        XCTAssertNotNil(analysisResult.rawAnalyzerOutput)

        let normalizedArtifact = try XCTUnwrap(artifacts.first(where: { $0.artifactType == "normalized_analysis" }))
        let normalizedArtifactURL = try XCTUnwrap(URL(string: normalizedArtifact.uri))
        let persistedNormalized = try decode(NormalizedAnalysisContract.self, from: String(decoding: Data(contentsOf: normalizedArtifactURL), as: UTF8.self))

        XCTAssertEqual(persistedNormalized.summary.beatCount, 5)
        XCTAssertEqual(persistedNormalized.summary.barCount, 2)
        XCTAssertEqual(persistedNormalized.drumEvents.count, 3)
        XCTAssertEqual(persistedNormalized.drumEvents.map(\.lane), [.kick, .snare, .hihatClosed])
        XCTAssertEqual(persistedNormalized.beatGrid.first(where: { $0.beatIndex == 0 })?.isDownbeat, true)
        XCTAssertEqual(persistedNormalized.beatGrid.first(where: { $0.beatIndex == 4 })?.isDownbeat, true)
        XCTAssertEqual(persistedNormalized.beatGrid.first(where: { $0.beatIndex == 0 })?.barIndex, 0)
        XCTAssertEqual(persistedNormalized.beatGrid.first(where: { $0.beatIndex == 4 })?.barIndex, 1)

        let baseChartArtifact = try XCTUnwrap(artifacts.first(where: { $0.artifactType == "base_chart" }))
        let baseChartArtifactURL = try XCTUnwrap(URL(string: baseChartArtifact.uri))
        let persistedBaseChart = try decode(BaseChartContract.self, from: String(decoding: Data(contentsOf: baseChartArtifactURL), as: UTF8.self))
        XCTAssertEqual(persistedBaseChart.chart.notes.count, 3)
        XCTAssertEqual(persistedBaseChart.chart.notes.map(\.lane), [.kick, .snare, .hihatClosed])
    }

    private func makeRuntime(databasePath: String, artifactRoot: String, analyzerCommand: String, acceptsStdoutJSON: Bool = false) -> PipelineRuntime {
        PipelineRuntime(
            configuration: SQLiteConfiguration(
                databasePath: databasePath,
                artifactRoot: artifactRoot,
                autoMigrate: true
            ),
            audioAnalyzerConfiguration: AudioAnalyzerConfiguration(
                commandTemplate: analyzerCommand,
                timeoutSeconds: nil,
                acceptsStdoutJSON: acceptsStdoutJSON
            )
        )
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

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
