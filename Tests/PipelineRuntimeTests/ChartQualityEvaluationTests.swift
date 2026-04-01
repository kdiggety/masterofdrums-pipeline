import XCTest
@testable import PipelineDomain

final class ChartQualityEvaluationTests: XCTestCase {
    func testCorpusFixtureDecodesAndDescribesMinimalSongSet() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "chart-eval-corpus", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(ChartEvaluationCorpus.self, from: data)

        XCTAssertEqual(corpus.schemaVersion, "1.2.0")
        XCTAssertEqual(corpus.songs.count, 1)

        let song = try XCTUnwrap(corpus.songs.first)
        XCTAssertEqual(song.id, "known-tone")
        XCTAssertEqual(song.sourceFixture, "known-tone.wav")
        XCTAssertEqual(song.sourceType, "fixture_audio")
        XCTAssertEqual(try XCTUnwrap(song.clipDurationSeconds), 1.0, accuracy: 0.0001)
        XCTAssertEqual(song.reviewStatus, "synthetic_smoke")
        XCTAssertEqual(song.reviewNotes.count, 2)
        XCTAssertEqual(song.tags, ["synthetic", "fixture", "smoke"])
        XCTAssertEqual(song.expectations.count, 2)

        let prototypeExpectation = try XCTUnwrap(song.expectations.first(where: { $0.difficulty == "prototype" }))
        XCTAssertEqual(prototypeExpectation.requiredLanes, [.kick, .snare])
        XCTAssertEqual(prototypeExpectation.allowedLanes ?? [], [.kick, .snare, .hihatClosed])
        XCTAssertEqual(prototypeExpectation.maxNotesPerBeat, 1)
        XCTAssertEqual(try XCTUnwrap(prototypeExpectation.minimumScore), 0.9, accuracy: 0.0001)

        let easyExpectation = try XCTUnwrap(song.expectations.first(where: { $0.difficulty == "easy" }))
        XCTAssertEqual(easyExpectation.requiredLanes, [.kick])
        XCTAssertEqual(easyExpectation.allowedLanes ?? [], [.kick, .snare, .hihatClosed])
        XCTAssertEqual(easyExpectation.minDistinctLanes, 1)
        XCTAssertEqual(easyExpectation.maxSimultaneousNotes, 1)
        XCTAssertEqual(easyExpectation.maxNotesPerMeasure, 8)
        XCTAssertEqual(easyExpectation.allowedEmptyMeasures, 1)
        XCTAssertEqual(try XCTUnwrap(easyExpectation.minimumScore), 0.7, accuracy: 0.0001)
    }

    func testEvaluatorPassesChartThatFitsFixtureExpectations() {
        let expectation = ChartQualityExpectation(
            difficulty: "easy",
            noteCountRange: .init(min: 2, max: 6),
            measureCountRange: .init(min: 1, max: 2),
            requiredLanes: [.kick, .snare],
            allowedLanes: [.kick, .snare, .hihatClosed],
            minDistinctLanes: 2,
            maxSimultaneousNotes: 1,
            maxNotesPerBeat: 2,
            maxNotesPerMeasure: 4,
            allowedEmptyMeasures: 0,
            minimumScore: 0.8
        )

        let chart = makeChart(
            difficulty: "easy",
            measures: 1,
            notes: [
                .init(lane: .kick, tick: 0, beatIndex: 0, startSeconds: 0.0),
                .init(lane: .snare, tick: 480, beatIndex: 1, startSeconds: 0.5),
                .init(lane: .hihatClosed, tick: 960, beatIndex: 2, startSeconds: 1.0)
            ]
        )

        let report = ChartQualityEvaluator.evaluate(chart: chart, against: expectation)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.issues.count, 0)
        XCTAssertEqual(report.metrics.noteCount, 3)
        XCTAssertEqual(report.metrics.measureCount, 1)
        XCTAssertEqual(report.metrics.maxSimultaneousNotes, 1)
        XCTAssertEqual(report.metrics.maxNotesPerBeat, 1)
        XCTAssertEqual(report.metrics.maxNotesPerMeasure, 3)
        XCTAssertEqual(report.metrics.emptyMeasureCount, 0)
        XCTAssertEqual(report.metrics.averageNotesPerMeasure, 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.metrics.laneUsage.count, 3)
        XCTAssertEqual(report.metrics.measureDensity.map(\.noteCount), [3])
        XCTAssertEqual(report.score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(report.regressionSnapshot.notePreview.count, 3)
        XCTAssertEqual(report.regressionSnapshot.notePreview.first, "tick=0:beat=0:sub=nil:lane=kick:vel=nil")
        XCTAssertEqual(report.regressionSnapshot.measureDensity.map(\.noteCount), [3])
        XCTAssertTrue(report.summary.contains("PASS"))
        XCTAssertTrue(report.regressionSummary.contains("note_preview"))
        XCTAssertTrue(report.regressionSummary.contains("measure_density m0=3"))
    }

    func testEvaluatorFlagsOverchartedUnexpectedLaneAndChording() {
        let expectation = ChartQualityExpectation(
            difficulty: "easy",
            noteCountRange: .init(min: 1, max: 4),
            measureCountRange: .init(min: 1, max: 1),
            requiredLanes: [.kick],
            allowedLanes: [.kick, .snare],
            minDistinctLanes: 1,
            maxSimultaneousNotes: 1,
            maxNotesPerBeat: 2,
            maxNotesPerMeasure: 4,
            allowedEmptyMeasures: 0,
            minimumScore: 0.9
        )

        let chart = makeChart(
            difficulty: "hard",
            measures: 2,
            notes: [
                .init(lane: .kick, tick: 0, beatIndex: 0, startSeconds: 0.0),
                .init(lane: .snare, tick: 0, beatIndex: 0, startSeconds: 0.0),
                .init(lane: .crash, tick: 0, beatIndex: 0, startSeconds: 0.0),
                .init(lane: .kick, tick: 120, beatIndex: 0, startSeconds: 0.125),
                .init(lane: .snare, tick: 240, beatIndex: 0, startSeconds: 0.25)
            ]
        )

        let report = ChartQualityEvaluator.evaluate(chart: chart, against: expectation)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.metrics.noteCount, 5)
        XCTAssertEqual(report.metrics.measureCount, 2)
        XCTAssertEqual(report.metrics.maxSimultaneousNotes, 3)
        XCTAssertEqual(report.metrics.maxNotesPerBeat, 5)
        XCTAssertEqual(report.metrics.maxNotesPerMeasure, 5)
        XCTAssertEqual(report.metrics.emptyMeasureCount, 1)
        XCTAssertEqual(report.metrics.measureDensity.map(\.noteCount), [5, 0])

        let codes = Set(report.issues.map(\.code))
        XCTAssertTrue(codes.contains("difficulty_mismatch"))
        XCTAssertTrue(codes.contains("note_count_out_of_range"))
        XCTAssertTrue(codes.contains("measure_count_out_of_range"))
        XCTAssertTrue(codes.contains("unexpected_lanes"))
        XCTAssertTrue(codes.contains("max_simultaneous_notes_exceeded"))
        XCTAssertTrue(codes.contains("max_notes_per_beat_exceeded"))
        XCTAssertTrue(codes.contains("max_notes_per_measure_exceeded"))
        XCTAssertTrue(codes.contains("too_many_empty_measures"))
        XCTAssertTrue(codes.contains("score_below_threshold"))
        XCTAssertEqual(report.score, 0.22, accuracy: 0.0001)
        XCTAssertTrue(report.summary.contains("FAIL"))
    }

    func testEvaluatorFlagsEmptyChartAndMissingRequiredLanes() {
        let expectation = ChartQualityExpectation(
            difficulty: "easy",
            noteCountRange: .init(min: 1, max: 8),
            measureCountRange: .init(min: 1, max: 2),
            requiredLanes: [.kick, .snare],
            allowedLanes: [.kick, .snare],
            minDistinctLanes: 2,
            maxSimultaneousNotes: 1,
            maxNotesPerBeat: 2,
            maxNotesPerMeasure: 4,
            allowedEmptyMeasures: 0,
            minimumScore: 0.5
        )

        let chart = makeChart(difficulty: "easy", measures: 1, notes: [])
        let report = ChartQualityEvaluator.evaluate(chart: chart, against: expectation)

        let codes = Set(report.issues.map(\.code))
        XCTAssertTrue(codes.contains("empty_chart"))
        XCTAssertTrue(codes.contains("note_count_out_of_range"))
        XCTAssertTrue(codes.contains("missing_required_lanes"))
        XCTAssertTrue(codes.contains("insufficient_lane_variety"))
        XCTAssertTrue(codes.contains("too_many_empty_measures"))
        XCTAssertTrue(codes.contains("score_below_threshold"))
        XCTAssertEqual(report.metrics.emptyMeasureCount, 1)
        XCTAssertEqual(report.metrics.maxNotesPerMeasure, 0)
        XCTAssertEqual(report.metrics.measureDensity.map(\.noteCount), [0])
        XCTAssertEqual(report.metrics.averageNotesPerMeasure, 0.0, accuracy: 0.0001)
        XCTAssertEqual(report.score, 0.0, accuracy: 0.0001)
    }

    func testCorpusRunnerProducesStableRegressionFriendlyTextReport() {
        let corpus = ChartEvaluationCorpus(
            songs: [
                ChartEvaluationSong(
                    id: "fixture-song",
                    title: "Fixture Song",
                    sourceFixture: "fixture.wav",
                    sourceType: "fixture_audio",
                    clipDurationSeconds: 1.0,
                    reviewStatus: "ready_for_regression",
                    reviewNotes: ["Human-review baseline once real clip arrives."],
                    tags: ["smoke", "fixture"],
                    expectations: [
                        ChartQualityExpectation(
                            difficulty: "prototype",
                            noteCountRange: .init(min: 2, max: 3),
                            measureCountRange: .init(min: 1, max: 1),
                            requiredLanes: [.kick, .snare],
                            allowedLanes: [.kick, .snare],
                            minDistinctLanes: 2,
                            maxSimultaneousNotes: 1,
                            maxNotesPerBeat: 1,
                            maxNotesPerMeasure: 3,
                            allowedEmptyMeasures: 0,
                            minimumScore: 0.9
                        )
                    ]
                )
            ]
        )

        let chart = makeChart(
            difficulty: "prototype",
            measures: 1,
            notes: [
                .init(lane: .kick, tick: 0, beatIndex: 0, subdivisionIndex: 0, startSeconds: 0.0, velocity: 1.0),
                .init(lane: .snare, tick: 480, beatIndex: 1, subdivisionIndex: 4, startSeconds: 0.5, velocity: 0.7)
            ]
        )

        let report = ChartEvaluationRunner.evaluate(
            corpus: corpus,
            generatedCharts: ["fixture-song": ["prototype": chart]],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.totalExpectations, 1)
        XCTAssertEqual(report.passedExpectations, 1)
        XCTAssertEqual(report.failedExpectations, 0)
        XCTAssertEqual(report.results.count, 1)
        XCTAssertEqual(report.tagSummaries.map(\.tag), ["fixture", "smoke"])
        XCTAssertEqual(report.tagSummaries.map(\.passedExpectations), [1, 1])

        let text = report.renderText()
        XCTAssertTrue(text.contains("corpus pass=1/1 failed=0 missing=0 tags=2"))
        XCTAssertTrue(text.contains("tag_summary fixture=1/1 smoke=1/1"))
        XCTAssertTrue(text.contains("fixture-song [prototype] PASS prototype score=1.00"))
        XCTAssertTrue(text.contains("source=fixture.wav"))
        XCTAssertTrue(text.contains("source_type=fixture_audio"))
        XCTAssertTrue(text.contains("review=ready_for_regression"))
        XCTAssertTrue(text.contains("lane_usage kick=1 snare=1"))
        XCTAssertTrue(text.contains("measure_density m0=2"))
        XCTAssertTrue(text.contains("tick=0:beat=0:sub=0:lane=kick:vel=1.00"))
        XCTAssertTrue(text.contains("tick=480:beat=1:sub=4:lane=snare:vel=0.70"))
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
