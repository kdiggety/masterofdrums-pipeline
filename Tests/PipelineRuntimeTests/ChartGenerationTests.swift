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

    func testGenerateInfersTripletSubdivisionFromAnalyzerEventTiming() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "bass drum", "onsetSeconds": 0.0, "velocity": 1.0],
                ["eventID": "snare-1", "label": "snare", "onsetSeconds": 0.333, "velocity": 0.8],
                ["eventID": "hat-1", "label": "closed hi hat", "onsetSeconds": 0.667, "velocity": 0.5]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.beatGrid.count, 9)
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [0, 320, 640])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [0, 2, 4])
        XCTAssertTrue(generated.normalized.note?.contains("3x") == true)
    }

    func testGenerateUsesExplicitAnalyzerSubdivisionAnchorsForBeatGridAndTicks() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5],
            "subdivisions": [0.0, 0.18, 0.31, 0.5, 0.68, 0.84],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.18, "velocity": 1.0],
                ["eventID": "snare-1", "label": "snare", "onsetSeconds": 0.84, "velocity": 0.8]
            ]
        ], duration: 1.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.beatGrid.count, 6)
        XCTAssertEqual(generated.normalized.beatGrid[1].startSeconds, 0.18, accuracy: 0.0001)
        XCTAssertEqual(generated.normalized.beatGrid[2].startSeconds, 0.31, accuracy: 0.0001)
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [173, 806])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [1, 5])
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
        XCTAssertEqual(try XCTUnwrap(generated.baseChart.chart.notes[0].velocity), 1.0, accuracy: 0.0001)
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("without onset timing") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("unmapped lanes") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Mapped 1 of 3 analyzer drum-event candidates") }))
    }

    func testGenerateDeduplicatesAnalyzerEventsThatCollapseIntoSameQuantizedLaneSlot() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "snare-weak", "label": "snare", "onsetSeconds": 0.49, "velocity": 0.4, "confidence": 0.4],
                ["eventID": "snare-strong", "label": "snare", "onsetSeconds": 0.48, "velocity": 0.9, "confidence": 0.9],
                ["eventID": "kick", "label": "kick", "onsetSeconds": 0.0, "velocity": 1.0, "confidence": 0.8]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.count, 2)
        XCTAssertEqual(generated.normalized.drumEvents.map(\.eventID), ["kick", "snare-strong"])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [0, 480])
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Collapsed 1 analyzer drum-event duplicates") }))
    }


    func testGenerateConsumesNestedTimingObjectsAndStructuredEventLabels() throws {
        let analysis = makeAnalysis(raw: [
            "result": [
                "timing": [
                    "beats": [
                        ["time": ["seconds": 0.0]],
                        ["position": ["seconds": 0.5]],
                        ["start": ["seconds": 1.0]]
                    ],
                    "subdivisions": [
                        ["start": ["seconds": 0.0]],
                        ["start": ["seconds": 0.25]],
                        ["start": ["seconds": 0.5]],
                        ["start": ["seconds": 0.75]],
                        ["start": ["seconds": 1.0]],
                        ["start": ["seconds": 1.25]]
                    ],
                    "downbeats": [["offset": ["seconds": 0.0]]]
                ],
                "drumEventCandidates": [
                    ["id": "kick-1", "position": ["seconds": 0.24], "instrument": ["label": "bass drum"], "velocity": 0.9],
                    ["id": "snare-1", "offset": ["seconds": 0.76], "class": ["name": "snare"], "strength": 0.8],
                    ["id": "hat-1", "onset": ["seconds": 1.24], "lane": ["name": "closed hat"], "amplitude": 0.5]
                ]
            ]
        ], duration: 1.5)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.summary.beatCount, 3)
        XCTAssertEqual(generated.normalized.beatGrid.count, 6)
        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.kick, .snare, .hihatClosed])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [240, 720, 1200])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [1, 3, 5])
    }

    func testGenerateConsumesTrackWrappedEventArrays() throws {
        let analysis = makeAnalysis(raw: [
            "payload": [
                "timing": [
                    "beat_times": [0.0, 0.5, 1.0],
                    "subdivisions_per_beat": 4
                ],
                "tracks": [
                    [
                        "name": "drums",
                        "events": [
                            ["id": "kick-1", "time": ["seconds": 0.01], "instrument": ["name": "kick"]],
                            ["id": "snare-1", "time": ["seconds": 0.49], "instrument": ["name": "snare"]]
                        ]
                    ]
                ]
            ]
        ], duration: 1.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.count, 2)
        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.kick, .snare])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [0, 480])
        XCTAssertTrue(generated.normalized.note?.contains("4x") == true)
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
