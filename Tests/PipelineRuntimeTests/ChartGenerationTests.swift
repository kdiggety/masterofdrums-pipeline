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
        XCTAssertEqual(generated.baseChart.timingContractVersion, "0.1.0")
        XCTAssertEqual(try XCTUnwrap(generated.baseChart.timing.bpm), 120, accuracy: 0.0001)
        XCTAssertEqual(generated.baseChart.timing.offsetSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(generated.baseChart.timing.ticksPerBeat, 480)
        XCTAssertEqual(generated.baseChart.timing.timeSignature.numerator, 4)
        XCTAssertEqual(generated.baseChart.timing.timeSignature.denominator, 4)
        XCTAssertEqual(generated.baseChart.timing.source, "generated")
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
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [0, 320])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [0, 2])
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

    func testGenerateRepairsSparseFirstBarUsingDownbeatCadence() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.02, 1.0, 2.0, 2.5, 3.0, 3.5, 4.0],
            "downbeats": [0.02, 2.0, 4.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.03, "velocity": 1.0],
                ["eventID": "snare-1", "label": "snare", "onsetSeconds": 1.02, "velocity": 0.8],
                ["eventID": "kick-2", "label": "kick", "onsetSeconds": 2.02, "velocity": 1.0]
            ]
        ], duration: 4.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.baseChart.timing.offsetSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(generated.normalized.summary.downbeatOffsetSeconds ?? 0, 0, accuracy: 0.0001)
        XCTAssertEqual(generated.normalized.summary.beatCount, 9)
        let beatStarts = generated.normalized.beatGrid.filter { $0.subdivisionInBeat == 0 }.map(\.startSeconds)
        XCTAssertEqual(beatStarts.count, 9)
        for (actual, expected) in zip(beatStarts, [0.0, 0.495, 0.99, 1.485, 1.98, 2.48, 2.98, 3.48, 3.98]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [40, 1000, 1960])
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
        XCTAssertEqual(generated.normalized.drumEventDiagnostics?.rawCandidateCount, 3)
        XCTAssertEqual(generated.normalized.drumEventDiagnostics?.mappedCandidateCount, 1)
        XCTAssertEqual(generated.normalized.drumEventDiagnostics?.postShapingEventCount, 1)
        XCTAssertEqual(generated.baseChart.drumEventDiagnostics?.rawCandidateCount, 3)
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("without onset timing") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("unmapped lanes") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Timing/events split: timing source=analyzer; drum-event source=analyzer") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Mapped 1 of 3 analyzer drum-event candidates") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Analyzer drum-event diagnostics: raw=3 mapped=1 post-shaping=1") }))
        XCTAssertEqual(generated.normalized.summary.sourceProvenance?.timingSource, "analyzer")
        XCTAssertEqual(generated.normalized.summary.sourceProvenance?.eventSource, "analyzer")
        XCTAssertTrue(generated.normalized.summary.operatorSummary?.laneSummary.contains("tom_low=1") == true)
        XCTAssertEqual(generated.normalized.summary.operatorSummary?.confidenceSummary, "high=1 medium=0 low=0 unknown=0")
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
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [0, 320])
        XCTAssertEqual(generated.normalized.drumEventDiagnostics?.rawCandidateCount, 3)
        XCTAssertEqual(generated.normalized.drumEventDiagnostics?.mappedCandidateCount, 3)
        XCTAssertEqual(generated.normalized.drumEventDiagnostics?.postShapingEventCount, 2)
        XCTAssertEqual(generated.normalized.drumEventDiagnostics?.deduplicatedCandidateCount, 1)
        XCTAssertEqual(generated.normalized.drumEventDiagnostics?.shapingReductionCount, 1)
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Timing/events split: timing source=analyzer; drum-event source=analyzer") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Collapsed") && $0.contains("analyzer drum-event duplicates") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Analyzer drum-event diagnostics: raw=3 mapped=3 post-shaping=2") }))
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
        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.kick, .snare])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [240, 720])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [1, 3])
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

        XCTAssertEqual(generated.normalized.drumEvents.count, 7)
        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.crash, .hihatClosed, .kick, .snare, .hihatClosed, .kick, .hihatClosed])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [0, 0, 0, 480, 960, 960, 1200])
        XCTAssertTrue(generated.normalized.note?.contains("4x") == true)
    }

    func testGenerateNormalizesNestedAnalyzerEventsAndMessyLabels() throws {
        let analysis = makeAnalysis(raw: [
            "response": [
                "timing": [
                    "beats": [
                        ["time": ["seconds": 0.0]],
                        ["time": ["seconds": 0.5]],
                        ["time": ["seconds": 1.0]]
                    ]
                ],
                "tracks": [
                    [
                        "items": [
                            ["event": ["position": ["seconds": 0.0], "instrument": ["name": "Kick Drum"]]],
                            ["event": ["position": ["seconds": 0.5], "instrument": ["label": "Side Stick"]]],
                            ["event": ["position": ["seconds": 0.75], "instrument": ["label": "Tom-3"]]]
                        ]
                    ]
                ]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.kick, .snare, .tomLow])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.tick), [0, 480, 720])
        XCTAssertFalse(generated.normalized.warnings.contains(where: { $0.contains("heuristic playable groove") }))
    }

    func testGenerateMapsMIDICodedADTOFStyleEventsIntoGameplayLanes() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "events": [
                ["id": "kick", "time": 0.0, "class": 35, "velocity": 0.95],
                ["id": "snare", "time": 0.5, "class": 38, "velocity": 0.80],
                ["id": "hat", "time": 0.75, "class": 42, "velocity": 0.60],
                ["id": "crash", "time": 1.0, "class": 49, "velocity": 0.90]
            ]
        ], duration: 1.5)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.kick, .snare, .crash])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.kick, .snare, .crash])
        XCTAssertFalse(generated.normalized.warnings.contains(where: { $0.contains("unmapped lanes") }))
    }

    func testGenerateShapesBeatThisStyleHatSpamIntoKickAnchoredPulseAndSelectiveTexture() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0, 1.5, 2.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95],
                ["eventID": "hat-1a", "label": "closed hat", "onsetSeconds": 0.0, "velocity": 0.55],
                ["eventID": "hat-1b", "label": "closed hat", "onsetSeconds": 0.125, "velocity": 0.52],
                ["eventID": "hat-1c", "label": "closed hat", "onsetSeconds": 0.25, "velocity": 0.50],
                ["eventID": "hat-1d", "label": "closed hat", "onsetSeconds": 0.375, "velocity": 0.48],
                ["eventID": "snare-2", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.92],
                ["eventID": "hat-2a", "label": "closed hat", "onsetSeconds": 0.5, "velocity": 0.55],
                ["eventID": "hat-2b", "label": "closed hat", "onsetSeconds": 0.625, "velocity": 0.52],
                ["eventID": "hat-2c", "label": "closed hat", "onsetSeconds": 0.75, "velocity": 0.50],
                ["eventID": "hat-2d", "label": "closed hat", "onsetSeconds": 0.875, "velocity": 0.48],
                ["eventID": "kick-3", "label": "kick", "onsetSeconds": 1.0, "velocity": 0.90],
                ["eventID": "hat-3a", "label": "closed hat", "onsetSeconds": 1.0, "velocity": 0.55],
                ["eventID": "hat-3b", "label": "closed hat", "onsetSeconds": 1.125, "velocity": 0.52],
                ["eventID": "hat-3c", "label": "closed hat", "onsetSeconds": 1.25, "velocity": 0.50],
                ["eventID": "hat-3d", "label": "closed hat", "onsetSeconds": 1.375, "velocity": 0.48],
                ["eventID": "snare-4", "label": "snare", "onsetSeconds": 1.5, "velocity": 0.92],
                ["eventID": "hat-4a", "label": "closed hat", "onsetSeconds": 1.5, "velocity": 0.55],
                ["eventID": "hat-4b", "label": "closed hat", "onsetSeconds": 1.625, "velocity": 0.52],
                ["eventID": "hat-4c", "label": "closed hat", "onsetSeconds": 1.75, "velocity": 0.50],
                ["eventID": "hat-4d", "label": "closed hat", "onsetSeconds": 1.875, "velocity": 0.48]
            ]
        ], duration: 2.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.filter { $0.lane == .hihatClosed }.count, 4)
        XCTAssertEqual(generated.baseChart.chart.notes.count, generated.normalized.drumEvents.count)
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), generated.normalized.drumEvents.map(\.lane))
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), generated.normalized.drumEvents.compactMap(\.onsetSubdivisionIndex))
        XCTAssertEqual(generated.baseChart.chart.notes.filter { $0.lane == .hihatClosed }.map(\.subdivisionIndex), [0, 1, 8, 9])
        XCTAssertEqual(generated.baseChart.chart.notes.filter { $0.lane == .kick || $0.lane == .snare }.map(\.lane), [.kick, .snare, .kick, .snare])
    }

    func testGenerateReportsAnalyzerShapingDiagnosticsBeforeBaseChartGeneration() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0, 1.5, 2.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95],
                ["eventID": "hat-1a", "label": "closed hat", "onsetSeconds": 0.0, "velocity": 0.55],
                ["eventID": "hat-1b", "label": "closed hat", "onsetSeconds": 0.125, "velocity": 0.52],
                ["eventID": "hat-1c", "label": "closed hat", "onsetSeconds": 0.25, "velocity": 0.50],
                ["eventID": "snare-2", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.92],
                ["eventID": "hat-2a", "label": "closed hat", "onsetSeconds": 0.5, "velocity": 0.55],
                ["eventID": "hat-2b", "label": "closed hat", "onsetSeconds": 0.625, "velocity": 0.52],
                ["eventID": "hat-2c", "label": "closed hat", "onsetSeconds": 0.75, "velocity": 0.50]
            ]
        ], duration: 2.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        let diagnostics = try XCTUnwrap(generated.normalized.drumEventDiagnostics)
        XCTAssertEqual(diagnostics.rawCandidateCount, 8)
        XCTAssertEqual(diagnostics.mappedCandidateCount, 8)
        XCTAssertEqual(diagnostics.postShapingEventCount, generated.normalized.drumEvents.count)
        XCTAssertEqual(generated.baseChart.chart.notes.count, diagnostics.postShapingEventCount)
        XCTAssertGreaterThan(diagnostics.shapingReductionCount, 0)
        XCTAssertEqual(generated.baseChart.drumEventDiagnostics?.postShapingEventCount, diagnostics.postShapingEventCount)
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Reduced analyzer-driven drum events by") }))
    }

    func testGenerateKeepsSparseHatPulseOnHatOnlyDownbeatsWithoutDroppingBackbone() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0, 1.5, 2.0],
            "drumEvents": [
                ["eventID": "hat-1a", "label": "closed hat", "onsetSeconds": 0.0, "velocity": 0.55],
                ["eventID": "hat-1b", "label": "closed hat", "onsetSeconds": 0.125, "velocity": 0.52],
                ["eventID": "snare-2", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.92],
                ["eventID": "hat-2a", "label": "closed hat", "onsetSeconds": 0.5, "velocity": 0.55],
                ["eventID": "kick-3", "label": "kick", "onsetSeconds": 1.0, "velocity": 0.90],
                ["eventID": "hat-3a", "label": "closed hat", "onsetSeconds": 1.0, "velocity": 0.55],
                ["eventID": "hat-3b", "label": "closed hat", "onsetSeconds": 1.125, "velocity": 0.52],
                ["eventID": "snare-4", "label": "snare", "onsetSeconds": 1.5, "velocity": 0.92],
                ["eventID": "hat-4a", "label": "closed hat", "onsetSeconds": 1.5, "velocity": 0.55]
            ]
        ], duration: 2.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.hihatClosed, .snare, .kick, .hihatClosed, .hihatClosed, .snare])
        XCTAssertEqual(generated.baseChart.chart.notes.filter { $0.lane == .hihatClosed }.map(\.subdivisionIndex), [0, 8, 9])
    }

    func testGeneratePrefersSingleBackboneLanePerBeatAndDropsSameBeatHatPileups() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95, "confidence": 0.95],
                ["eventID": "snare-1", "label": "snare", "onsetSeconds": 0.0, "velocity": 0.70, "confidence": 0.70],
                ["eventID": "hat-1", "label": "closed hat", "onsetSeconds": 0.0, "velocity": 0.55],
                ["eventID": "hat-2", "label": "closed hat", "onsetSeconds": 0.125, "velocity": 0.50],
                ["eventID": "snare-2", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.94, "confidence": 0.94],
                ["eventID": "kick-2", "label": "kick", "onsetSeconds": 0.5, "velocity": 0.60, "confidence": 0.60],
                ["eventID": "hat-3", "label": "closed hat", "onsetSeconds": 0.5, "velocity": 0.55],
                ["eventID": "hat-4", "label": "closed hat", "onsetSeconds": 0.625, "velocity": 0.50]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.eventID), ["kick-1", "hat-1", "hat-2", "snare-2"])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.kick, .hihatClosed, .hihatClosed, .snare])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [0, 0, 1, 4])
    }

    func testGenerateKeepsCrashAccentOnDownbeatWithoutKeepingExtraBackboneStack() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "kick", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95],
                ["eventID": "snare", "label": "snare", "onsetSeconds": 0.0, "velocity": 0.60],
                ["eventID": "crash", "label": "crash", "onsetSeconds": 0.0, "velocity": 0.90],
                ["eventID": "hat", "label": "closed hat", "onsetSeconds": 0.125, "velocity": 0.50]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.kick, .crash, .hihatClosed])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.kick, .crash, .hihatClosed])
    }

    func testGenerateLetsClearlyStrongerBackboneCandidateOverrideBeatBias() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "kick-weak", "label": "kick", "onsetSeconds": 0.5, "velocity": 0.45, "confidence": 0.45],
                ["eventID": "snare-strong", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.92, "confidence": 0.92],
                ["eventID": "hat", "label": "closed hat", "onsetSeconds": 0.5, "velocity": 0.50]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.eventID), ["snare-strong"])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.snare])
    }

    func testGeneratePreservesRapidKickDoublesAcrossDistinctSubdivisionsInSameBeat() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "subdivisions": [0.0, 0.083333, 0.166667, 0.25, 0.333333, 0.416667, 0.5, 0.583333, 0.666667, 0.75, 0.833333, 0.916667, 1.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95, "confidence": 0.95],
                ["eventID": "kick-2", "label": "kick", "onsetSeconds": 0.166667, "velocity": 0.91, "confidence": 0.91],
                ["eventID": "snare-1", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.92, "confidence": 0.92]
            ]
        ], duration: 1.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.eventID), ["kick-1", "kick-2", "snare-1"])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.kick, .kick, .snare])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [0, 2, 6])
    }

    func testGeneratePreservesDenseTrapBackboneAcrossOneBeatWhenSubdivisionsDiffer() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "subdivisions": [0.0, 0.083333, 0.166667, 0.25, 0.333333, 0.416667, 0.5, 0.583333, 0.666667, 0.75, 0.833333, 0.916667, 1.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95, "confidence": 0.95],
                ["eventID": "snare-ghost", "label": "snare", "onsetSeconds": 0.166667, "velocity": 0.61, "confidence": 0.61],
                ["eventID": "kick-3", "label": "kick", "onsetSeconds": 0.333333, "velocity": 0.90, "confidence": 0.90],
                ["eventID": "snare-2", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.94, "confidence": 0.94]
            ]
        ], duration: 1.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.eventID), ["kick-1", "snare-ghost", "kick-3", "snare-2"])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.kick, .snare, .kick, .snare])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [0, 2, 4, 6])
    }

    func testGenerateInfersDenserSubdivisionGridForRapidTrapKickSequence() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95, "confidence": 0.95],
                ["eventID": "kick-2", "label": "kick", "onsetSeconds": 0.125, "velocity": 0.91, "confidence": 0.91],
                ["eventID": "kick-3", "label": "kick", "onsetSeconds": 0.1875, "velocity": 0.89, "confidence": 0.89],
                ["eventID": "snare-1", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.93, "confidence": 0.93]
            ]
        ], duration: 1.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.eventID), ["kick-1", "kick-2", "kick-3", "snare-1"])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.kick, .kick, .kick, .snare])
        XCTAssertEqual(generated.baseChart.chart.notes.prefix(3).compactMap(\.subdivisionIndex), [0, 4, 6])
        XCTAssertEqual(generated.baseChart.chart.notes.prefix(3).map(\.tick), [0, 120, 180])
    }

    func testGeneratePreservesOpenHatAccentAlongsideClosedPulseWhenKickAnchored() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "kick", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95],
                ["eventID": "hat-closed", "label": "closed hat", "onsetSeconds": 0.0, "velocity": 0.55],
                ["eventID": "hat-open", "label": "open hat", "onsetSeconds": 0.125, "velocity": 0.80, "confidence": 0.80],
                ["eventID": "hat-texture", "label": "closed hat", "onsetSeconds": 0.25, "velocity": 0.40]
            ]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.kick, .hihatClosed, .hihatOpen])
        XCTAssertEqual(generated.normalized.drumEvents.map(\.eventID), ["kick", "hat-closed", "hat-open"])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.kick, .hihatClosed, .hihatOpen])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.subdivisionIndex), [0, 0, 1])
    }

    func testGeneratePreservesTomFillMotionAndCrashTransitionWithoutHatClutter() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0, 1.5, 2.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "velocity": 0.95],
                ["eventID": "hat-1", "label": "closed hat", "onsetSeconds": 0.0, "velocity": 0.55],
                ["eventID": "tom-high", "label": "rack tom 1", "onsetSeconds": 1.0, "velocity": 0.78],
                ["eventID": "kick-under-fill", "label": "kick", "onsetSeconds": 1.0, "velocity": 0.82],
                ["eventID": "hat-fill", "label": "closed hat", "onsetSeconds": 1.125, "velocity": 0.50],
                ["eventID": "tom-mid", "label": "middle rack tom", "onsetSeconds": 1.5, "velocity": 0.80],
                ["eventID": "crash-resolve", "label": "crash", "onsetSeconds": 1.5, "velocity": 0.92],
                ["eventID": "snare-under-fill", "label": "snare", "onsetSeconds": 1.5, "velocity": 0.60],
                ["eventID": "hat-resolve", "label": "closed hat", "onsetSeconds": 1.625, "velocity": 0.48]
            ]
        ], duration: 2.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.eventID), ["kick-1", "hat-1", "kick-under-fill", "tom-high", "crash-resolve", "tom-mid", "snare-under-fill"])
        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.kick, .hihatClosed, .kick, .tomHigh, .crash, .tomMid, .snare])
        XCTAssertFalse(generated.normalized.drumEvents.contains(where: { $0.eventID == "hat-fill" || $0.eventID == "hat-resolve" }))
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.kick, .hihatClosed, .kick, .tomHigh, .crash, .tomMid, .snare])
    }

    func testGenerateMapsExpandedTomAliasesToGameplayLanes() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0, 1.5],
            "drumEvents": [
                ["eventID": "low", "label": "low floor tom", "onsetSeconds": 0.0, "velocity": 0.7],
                ["eventID": "mid", "label": "middle rack tom", "onsetSeconds": 0.5, "velocity": 0.7],
                ["eventID": "high", "label": "rack tom 2", "onsetSeconds": 1.0, "velocity": 0.7]
            ]
        ], duration: 1.5)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.drumEvents.map(\.lane), [.tomLow, .tomMid, .tomHigh])
        XCTAssertEqual(generated.baseChart.chart.notes.map(\.lane), [.tomLow, .tomMid, .tomHigh])
    }

    func testGenerateUsesSparserHeuristicGrooveWhenAnalyzerTimingHasNoDrumEvents() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0, 1.5, 2.0]
        ], duration: 2.0)

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertEqual(generated.normalized.summary.beatCount, 5)
        XCTAssertEqual(generated.normalized.drumEvents.filter { $0.lane == .kick || $0.lane == .snare }.map(\.lane), [.kick, .snare, .kick, .snare, .kick])
        XCTAssertEqual(generated.normalized.drumEvents.filter { $0.lane == .hihatClosed }.map(\.onsetSubdivisionIndex), [0, 8, 10, 16])
        XCTAssertEqual(generated.normalized.drumEvents.filter { $0.lane == .hihatClosed }.count, 4)
        XCTAssertEqual(generated.normalized.drumEvents.filter { $0.lane == .crash }.count, 1)
        XCTAssertEqual(generated.baseChart.chart.notes.count, generated.normalized.drumEvents.count)
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Analyzer timing was preserved, but analyzer drum-event candidates were unusable; heuristicDrumEvents supplied the playable drum events instead.") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Timing/events split: timing source=analyzer; drum-event source=heuristicDrumEvents") }))
        XCTAssertTrue(generated.normalized.note?.contains("analyzer-provided timing") == true)
        XCTAssertTrue(generated.normalized.note?.contains("heuristicDrumEvents fallback shaping") == true)
        XCTAssertTrue(generated.baseChart.note?.contains("heuristicDrumEvents fallback output") == true)
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
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Analyzer did not provide usable timing or drum-event candidates") }))
        XCTAssertTrue(generated.normalized.note?.contains("4x fallback subdivision") == true)
    }

    func testGenerateMakesTimingVsEventSourcesExplicitWhenAnalyzerOnlyProvidesTiming() throws {
        let analysis = makeAnalysis(raw: [
            "beats": [0.0, 0.5, 1.0],
            "downbeats": [0.0]
        ])

        let generated = ChartGenerator.generate(
            from: analysis,
            generatedAt: Date(timeIntervalSince1970: 0),
            normalizedAnalysisArtifactURI: "file:///tmp/normalized.json"
        )

        XCTAssertFalse(generated.normalized.beatGrid.isEmpty)
        XCTAssertFalse(generated.normalized.drumEvents.isEmpty)
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Analyzer timing was preserved, but analyzer drum-event candidates were unusable; heuristicDrumEvents supplied the playable drum events instead.") }))
        XCTAssertTrue(generated.normalized.warnings.contains(where: { $0.contains("Timing/events split: timing source=analyzer; drum-event source=heuristicDrumEvents") }))
        XCTAssertTrue(generated.normalized.note?.contains("analyzer-provided timing") == true)
        XCTAssertTrue(generated.normalized.note?.contains("heuristicDrumEvents fallback shaping") == true)
        XCTAssertTrue(generated.baseChart.note?.contains("analyzer-provided timing") == true)
        XCTAssertTrue(generated.baseChart.note?.contains("heuristicDrumEvents fallback output") == true)
        XCTAssertEqual(generated.normalized.summary.sourceProvenance?.timingSource, "analyzer")
        XCTAssertEqual(generated.normalized.summary.sourceProvenance?.eventSource, "heuristicDrumEvents")
        XCTAssertEqual(generated.normalized.summary.sourceProvenance?.eventBackend, "heuristicDrumEvents")
        XCTAssertTrue(generated.normalized.summary.operatorSummary?.sourceSummary.contains("events=heuristicDrumEvents") == true)
        XCTAssertTrue(generated.normalized.summary.operatorSummary?.warningSummary?.contains("heuristicDrumEvents supplied the playable drum events instead") == true)
    }

    func testAudioAnalysisContractCapturesStage2EventBackendProvenanceSeparatelyFromTiming() throws {
        let payload: [String: Any] = [
            "analysis": [
                "audioTrackCount": 1,
                "estimatedSegmentCount": 1,
                "durationSeconds": 1.0,
                "estimatedTempoBPM": 120.0,
                "confidence": 0.8
            ],
            "beats": [0.0, 0.5, 1.0],
            "drumEvents": [
                ["eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "confidence": 0.95]
            ],
            "runtime": [
                "backend": "scripts/hybrid-drum-events-backend.py",
                "selectedBackend": "primary",
                "timingBackendCommand": "python scripts/backend-analyzer.py --input {input} --output {output}",
                "eventBackendRan": true,
                "eventBackendUsed": true,
                "eventBackendCandidateCount": 1,
                "eventBackendCommand": "python scripts/backend-analyzer.py --input {input} --output {output}",
                "eventBackendRuntime": ["backend": "fixture-event"]
            ]
        ]

        let analysis = AudioAnalysisContract.fromAnalyzerOutput(
            payload,
            sourceType: "file",
            sourceURI: "file:///tmp/test.wav",
            requestedBy: "test",
            analyzedAt: Date(timeIntervalSince1970: 0),
            commandTemplate: "test"
        )

        XCTAssertEqual(analysis.analysis.timingProvenance?.backend, "heuristic_backend")
        XCTAssertEqual(analysis.analysis.eventProvenance?.backend, "fixture-event")
        XCTAssertEqual(analysis.analysis.eventProvenance?.eventSource, "stage2_backend")
        XCTAssertTrue(analysis.analysis.operatorSummaryLine.contains("events=fixture-event via stage2_backend, used=yes"))
    }

    func testAudioAnalysisContractMarksEmptyStage2EventBackendAsAuditedButUnused() throws {
        let payload: [String: Any] = [
            "analysis": [
                "audioTrackCount": 1,
                "estimatedSegmentCount": 1,
                "durationSeconds": 1.0,
                "estimatedTempoBPM": 120.0,
                "confidence": 0.8
            ],
            "beats": [0.0, 0.5, 1.0],
            "runtime": [
                "backend": "scripts/hybrid-drum-events-backend.py",
                "selectedBackend": "primary",
                "timingBackendCommand": "python scripts/beat-this-backend.py --input {input} --output {output}",
                "eventBackendRan": true,
                "eventBackendUsed": false,
                "eventBackendCandidateCount": 0,
                "eventBackendCommand": "python scripts/adtof-output-adapter.py --input {input} --output {output}",
                "eventBackendRuntime": ["backend": "fixture-adtof"]
            ]
        ]

        let analysis = AudioAnalysisContract.fromAnalyzerOutput(
            payload,
            sourceType: "file",
            sourceURI: "file:///tmp/test.wav",
            requestedBy: "test",
            analyzedAt: Date(timeIntervalSince1970: 0),
            commandTemplate: "test"
        )

        XCTAssertEqual(analysis.analysis.timingProvenance?.backend, "beat_this")
        XCTAssertEqual(analysis.analysis.eventProvenance?.backend, "fixture-adtof")
        XCTAssertEqual(analysis.analysis.eventProvenance?.eventSource, "stage2_backend_empty")
        XCTAssertFalse(analysis.analysis.eventProvenance?.backendUsed ?? true)
        XCTAssertEqual(analysis.analysis.eventProvenance?.failureSummary?.category, "empty")
        XCTAssertTrue(analysis.analysis.operatorSummaryLine.contains("events=fixture-adtof via stage2_backend_empty, used=no"))
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
