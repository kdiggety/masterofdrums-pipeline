import XCTest
@testable import PipelineRuntime
import PipelineDomain

final class ChartGenerationTests: XCTestCase {
    func testGenerateUsesQuarterBeatSubdivisionAnchorsForAnalyzerTiming() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.12, "velocity": 1.0],
                ["eventID": "hat-1", "label": "closed hat", "onsetSeconds": 0.38, "velocity": 0.5]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.summary.beatCount, 3)
        XCTAssertEqual(generated.normalized.beatGrid.count, 12)
        XCTAssertEqual(generated.baseChart.chart.notes.count, 2)
        XCTAssertEqual(generated.baseChart.chart.notes[0].tick, 120)
        XCTAssertEqual(generated.baseChart.chart.notes[0].subdivisionIndex, 1)
        XCTAssertEqual(generated.baseChart.chart.notes[1].tick, 360)
        XCTAssertEqual(generated.baseChart.chart.notes[1].lane, .hihatClosed)
        XCTAssertTrue(generated.baseChart.note?.contains("4x") == true)
    }

    func testGenerateWarnsWhenCandidatesAreDroppedAndMapsLaneAliases() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5],
            "drumEvents": [
                ["eventID": "good", "label": "floor tom", "onsetSeconds": 0.48, "velocity": 1.3],
                ["eventID": "missing-onset", "label": "snare"],
                ["eventID": "unknown-lane", "label": "laser", "onsetSeconds": 0.1]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.count, 1)
        XCTAssertEqual(generated.normalized.drumEvents[0].lane, .tomLow)
        XCTAssertEqual(generated.baseChart.chart.notes[0].velocity, 1.0, accuracy: 0.0001)
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("without onset timing") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("unmapped lanes") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Mapped 1 of 3 analyzer drum-event candidates") }))
    }

    func testGenerateFallsBackToDeterministicQuarterNoteGridWithoutAnalyzerEvents() throws {
        let analysis = makeAnalysis(raw: [:], tempo: nil, duration: 1.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.beatGrid.count, 8)
        XCTAssertEqual(generated.normalized.beatGrid[1].subdivisionInBeat, 1)
        XCTAssertEqual(generated.normalized.beatGrid[2].subdivisionInBeat, 2)
        XCTAssertEqual(generated.baseChart.chart.notes.first?.tick, 0)
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("fallback 120 BPM") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("heuristic playable groove") }))
        XCTAssertTrue(generated.normalized.note?.contains("4x fallback subdivision") == true)
    }

    private func makeAnalysis(raw: [String: Any], tempo: Double? = 120.0, duration: Double? = 1.0) -> AudioAnalysisContract {
        AudioAnalysisContract(
            source: AudioAnalysisSource(sourceType: "file", sourceURI: "file:///tmp/test.wav", requestedBy: "test"),
            analysis: AudioAnalysisSummary(
                analyzedAt: Date(timeIntervalSince1970: 0),
                durationSeconds: duration,
                audioTrackCount: 1,
                estimatedSegmentCount: 1,
                estimatedTempoBPM: tempo,
                downbeatOffsetSeconds: 0,
                confidence: 0.9,
                artifactURI: "file:///tmp/audio-analysis.json",
                analyzerCommand: "test"
            ),
            segments: [],
            warnings: [],
            note: nil,
            rawAnalyzerOutput: RawJSONValue.from(raw)
        )
    }
}
