import XCTest
@testable import PipelineRuntime
@testable import PipelineDomain

final class ChartCorpusEvaluatorHarnessTests: XCTestCase {
    func testCLIParserRecognizesEvaluateChartCorpusCommand() {
        let command = PipelineCLIParser.parse(arguments: [
            "MasterOfDrumsPipeline",
            "evaluate-chart-corpus",
            "--corpus", "/tmp/corpus.json",
            "--charts-dir", "/tmp/charts",
            "--baseline-charts-dir", "/tmp/baseline-charts",
            "--song-id", "known-tone",
            "--tag", "smoke",
            "--output-path", "/tmp/report.json",
            "--text-output-path", "/tmp/report.txt"
        ])

        XCTAssertEqual(
            command,
            .evaluateChartCorpus(
                corpusPath: "/tmp/corpus.json",
                chartsDirectory: "/tmp/charts",
                baselineChartsDirectory: "/tmp/baseline-charts",
                songID: "known-tone",
                tag: "smoke",
                outputPath: "/tmp/report.json",
                textOutputPath: "/tmp/report.txt"
            )
        )
    }

    func testHarnessLoadsChartsFromSongDifficultyFileNamesAndFiltersCorpus() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("masterofdrums-pipeline-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let corpus = ChartEvaluationCorpus(
            songs: [
                ChartEvaluationSong(
                    id: "known-tone",
                    title: "Known Tone",
                    sourceFixture: "known-tone.wav",
                    tags: ["smoke", "fixture"],
                    expectations: [
                        ChartQualityExpectation(
                            difficulty: "prototype",
                            noteCountRange: .init(min: 2, max: 4),
                            measureCountRange: .init(min: 1, max: 1),
                            requiredLanes: [.kick, .snare],
                            allowedLanes: [.kick, .snare, .hihatClosed],
                            minDistinctLanes: 2,
                            maxSimultaneousNotes: 1,
                            maxNotesPerBeat: 2,
                            maxNotesPerMeasure: 4,
                            allowedEmptyMeasures: 0,
                            minimumScore: 0.9,
                            focusedLaneExpectations: [
                                .init(lane: .kick, shareRange: .init(min: 0.2, max: 0.5), notesPerMeasureRange: .init(min: 0.5, max: 2.0), minNoteCount: 1),
                                .init(lane: .snare, shareRange: .init(min: 0.2, max: 0.5), notesPerMeasureRange: .init(min: 0.5, max: 2.0), minNoteCount: 1)
                            ]
                        )
                    ]
                ),
                ChartEvaluationSong(
                    id: "other-song",
                    title: "Other",
                    sourceFixture: "other.wav",
                    tags: ["regression"],
                    expectations: [ChartQualityExpectation(difficulty: "prototype")]
                )
            ]
        )

        let corpusURL = tempRoot.appendingPathComponent("corpus.json")
        try JSONEncoder.pipeline.encode(corpus).write(to: corpusURL)

        let chartsDir = tempRoot.appendingPathComponent("charts", isDirectory: true)
        try FileManager.default.createDirectory(at: chartsDir, withIntermediateDirectories: true)
        let chart = makeChart(
            difficulty: "prototype",
            measures: 1,
            notes: [
                .init(lane: .kick, tick: 0, beatIndex: 0, startSeconds: 0.0),
                .init(lane: .snare, tick: 480, beatIndex: 1, startSeconds: 0.5),
                .init(lane: .hihatClosed, tick: 960, beatIndex: 2, startSeconds: 1.0)
            ]
        )
        try JSONEncoder.pipeline.encode(chart).write(to: chartsDir.appendingPathComponent("known-tone--prototype.json"))

        let baselineChartsDir = tempRoot.appendingPathComponent("baseline-charts", isDirectory: true)
        try FileManager.default.createDirectory(at: baselineChartsDir, withIntermediateDirectories: true)
        let baselineChart = makeChart(
            difficulty: "prototype",
            measures: 1,
            notes: [
                .init(lane: .kick, tick: 0, beatIndex: 0, startSeconds: 0.0),
                .init(lane: .snare, tick: 480, beatIndex: 1, startSeconds: 0.5)
            ]
        )
        try JSONEncoder.pipeline.encode(baselineChart).write(to: baselineChartsDir.appendingPathComponent("known-tone--prototype.json"))

        let packaged = try ChartCorpusEvaluatorHarness.evaluate(
            corpusURL: corpusURL,
            chartsDirectoryURL: chartsDir,
            baselineChartsDirectoryURL: baselineChartsDir,
            selection: .init(songID: "known-tone", tag: "smoke")
        )

        XCTAssertEqual(packaged.summary.totalExpectations, 1)
        XCTAssertEqual(packaged.summary.passedExpectations, 1)
        XCTAssertEqual(packaged.summary.failedExpectations, 0)
        XCTAssertEqual(packaged.report.results.count, 1)
        XCTAssertEqual(packaged.report.comparisonCount, 1)
        XCTAssertTrue(packaged.text.contains("known-tone [prototype] PASS"))
        XCTAssertFalse(packaged.text.contains("other-song"))
        XCTAssertTrue(packaged.text.contains("compare status=regressed baseline=prototype candidate=prototype pass=true->true score=+0.00 notes=+1 measures=+0 avg_notes_per_measure=+1.00"))
        XCTAssertTrue(packaged.text.contains("highlights=note_drift=+1 (50.00%); density_shift=+1.00"))
        XCTAssertTrue(packaged.text.contains("comparison_summary watch=0 severe=1"))
        XCTAssertTrue(packaged.text.contains("preview_added=tick=960:beat=2:sub=nil:lane=hihat_closed:vel=nil"))
        XCTAssertTrue(packaged.text.contains("focused_lane_balance kick=1@0.33 snare=1@0.33 hihat_closed=1@0.33"))
    }

    func testParseStemSupportsSongDifficultyConvention() {
        let parsed = ChartCorpusEvaluatorHarness.parseStem("known-tone--prototype")
        XCTAssertEqual(parsed?.0, "known-tone")
        XCTAssertEqual(parsed?.1, "prototype")
    }

    private func makeChart(difficulty: String, measures: Int, notes: [BaseChartNote]) -> BaseChartContract {
        let chartMeasures = (0..<measures).map {
            BaseChartMeasure(barIndex: $0, startBeatIndex: $0 * 4, beatCount: 4, timeSignature: .init(numerator: 4, denominator: 4))
        }

        return BaseChartContract(
            source: BaseChartSource(
                normalizedAnalysisArtifactURI: "file:///tmp/normalized.json",
                sourceType: "file",
                sourceURI: "file:///tmp/source.wav",
                requestedBy: "test"
            ),
            timing: BaseChartTiming(
                bpm: 120,
                offsetSeconds: 0,
                ticksPerBeat: 480,
                timeSignature: .init(numerator: 4, denominator: 4),
                source: "fallback"
            ),
            chart: BaseChartData(
                generatedAt: Date(timeIntervalSince1970: 0),
                lanes: Array(Set(notes.map(\.lane))).sorted { $0.rawValue < $1.rawValue },
                difficulty: difficulty,
                measures: chartMeasures,
                notes: notes
            )
        )
    }
}
