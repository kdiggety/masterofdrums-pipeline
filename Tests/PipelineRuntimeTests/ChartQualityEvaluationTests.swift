import XCTest
@testable import PipelineDomain

final class ChartQualityEvaluationTests: XCTestCase {
    func testCorpusFixtureDecodesAndDescribesMinimalSongSet() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "chart-eval-corpus", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(ChartEvaluationCorpus.self, from: data)

        XCTAssertEqual(corpus.schemaVersion, "1.3.0")
        XCTAssertEqual(corpus.songs.count, 2)

        let song = try XCTUnwrap(corpus.songs.first(where: { $0.id == "known-tone" }))
        XCTAssertEqual(song.sourceFixture, "known-tone.wav")
        XCTAssertEqual(song.sourceType, "fixture_audio")
        XCTAssertEqual(try XCTUnwrap(song.clipDurationSeconds), 1.0, accuracy: 0.0001)
        XCTAssertEqual(song.reviewStatus, "synthetic_smoke")
        XCTAssertEqual(song.baselineStatus, "prototype_fixture")
        XCTAssertNil(song.baselineChartID)
        XCTAssertEqual(song.reviewNotes.count, 2)
        XCTAssertEqual(song.reviewChecklist.count, 2)
        XCTAssertEqual(song.tags, ["synthetic", "fixture", "smoke"])
        XCTAssertEqual(song.expectations.count, 2)

        let prototypeExpectation = try XCTUnwrap(song.expectations.first(where: { $0.difficulty == "prototype" }))
        XCTAssertEqual(prototypeExpectation.requiredLanes, [.kick, .snare])
        XCTAssertEqual(prototypeExpectation.allowedLanes ?? [], [.kick, .snare, .hihatClosed])
        XCTAssertEqual(prototypeExpectation.maxNotesPerBeat, 1)
        XCTAssertEqual(try XCTUnwrap(prototypeExpectation.minimumScore), 0.9, accuracy: 0.0001)

        let realClip = try XCTUnwrap(corpus.songs.first(where: { $0.id == "real-review-template" }))
        XCTAssertEqual(realClip.sourceType, "real_clip")
        XCTAssertEqual(realClip.reviewStatus, "awaiting_baseline_review")
        XCTAssertEqual(realClip.baselineStatus, "pending_review")
        XCTAssertEqual(realClip.reviewChecklist.count, 3)
        XCTAssertEqual(realClip.tags, ["regression", "real_clip", "fills"])
        XCTAssertEqual(realClip.expectations.count, 1)
    }

    func testCorpusLinterWarnsWhenRealClipMetadataIsIncomplete() {
        let corpus = ChartEvaluationCorpus(
            songs: [
                ChartEvaluationSong(
                    id: "real-1",
                    title: "Real One",
                    sourceFixture: "real-1.wav",
                    sourceType: "real_clip",
                    reviewStatus: nil,
                    baselineStatus: "approved_baseline",
                    reviewNotes: [],
                    reviewChecklist: [],
                    tags: ["fills"],
                    expectations: [ChartQualityExpectation(difficulty: "prototype")]
                )
            ]
        )

        let issues = ChartEvaluationCorpusLinter.lint(corpus)
        let codes = Set(issues.map(\.code))
        XCTAssertTrue(codes.contains("missing_source_provenance"))
        XCTAssertTrue(codes.contains("missing_review_status"))
        XCTAssertTrue(codes.contains("missing_review_notes"))
        XCTAssertTrue(codes.contains("missing_review_checklist"))
        XCTAssertTrue(codes.contains("missing_execution_tag"))
        XCTAssertTrue(codes.contains("missing_baseline_chart_id"))
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
        XCTAssertEqual(report.metrics.focusedLaneBalance.map(\.lane), [.kick, .snare, .hihatClosed])
        XCTAssertEqual(report.metrics.focusedLaneBalance.map(\.noteCount), [1, 1, 1])
        XCTAssertEqual(report.metrics.focusedLaneBalance.count, 3)
        XCTAssertEqual(report.metrics.focusedLaneBalance[0].noteShare, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.metrics.focusedLaneBalance[1].noteShare, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.metrics.focusedLaneBalance[2].noteShare, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.score, 1.0, accuracy: 0.0001)
        XCTAssertEqual(report.regressionSnapshot.notePreview.count, 3)
        XCTAssertEqual(report.regressionSnapshot.notePreview.first, "tick=0:beat=0:sub=nil:lane=kick:vel=nil")
        XCTAssertEqual(report.regressionSnapshot.measureDensity.map(\.noteCount), [3])
        XCTAssertEqual(report.regressionSnapshot.focusedLaneBalance.map(\.lane), ["kick", "snare", "hihat_closed"])
        XCTAssertTrue(report.summary.contains("PASS"))
        XCTAssertTrue(report.regressionSummary.contains("note_preview"))
        XCTAssertTrue(report.regressionSummary.contains("measure_density m0=3"))
        XCTAssertTrue(report.regressionSummary.contains("focused_lane_balance kick=1@0.33 snare=1@0.33 hihat_closed=1@0.33"))
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


    func testEvaluatorFlagsFocusedLaneDistributionAndDensityDrift() {
        let expectation = ChartQualityExpectation(
            difficulty: "prototype",
            noteCountRange: .init(min: 4, max: 8),
            measureCountRange: .init(min: 2, max: 2),
            requiredLanes: [.kick, .snare, .hihatClosed],
            allowedLanes: [.kick, .snare, .hihatClosed],
            minDistinctLanes: 3,
            maxSimultaneousNotes: 1,
            maxNotesPerBeat: 2,
            maxNotesPerMeasure: 5,
            allowedEmptyMeasures: 0,
            minimumScore: 0.8,
            focusedLaneExpectations: [
                .init(lane: .kick, shareRange: .init(min: 0.20, max: 0.45), notesPerMeasureRange: .init(min: 0.5, max: 1.5), minNoteCount: 1, maxNoteCount: 3),
                .init(lane: .snare, shareRange: .init(min: 0.20, max: 0.45), notesPerMeasureRange: .init(min: 0.5, max: 1.5), minNoteCount: 1, maxNoteCount: 3),
                .init(lane: .hihatClosed, shareRange: .init(min: 0.25, max: 0.60), notesPerMeasureRange: .init(min: 1.0, max: 2.5), minNoteCount: 2, maxNoteCount: 5)
            ]
        )

        let chart = makeChart(
            difficulty: "prototype",
            measures: 2,
            notes: [
                .init(lane: .kick, tick: 0, beatIndex: 0, startSeconds: 0.0),
                .init(lane: .kick, tick: 240, beatIndex: 0, startSeconds: 0.25),
                .init(lane: .kick, tick: 480, beatIndex: 1, startSeconds: 0.5),
                .init(lane: .kick, tick: 720, beatIndex: 1, startSeconds: 0.75),
                .init(lane: .snare, tick: 960, beatIndex: 2, startSeconds: 1.0),
                .init(lane: .hihatClosed, tick: 1440, beatIndex: 3, startSeconds: 1.5)
            ]
        )

        let report = ChartQualityEvaluator.evaluate(chart: chart, against: expectation)
        let codes = Set(report.issues.map(\.code))
        XCTAssertTrue(codes.contains("focused_lane_share_out_of_range"))
        XCTAssertTrue(codes.contains("focused_lane_density_out_of_range"))
        XCTAssertTrue(codes.contains("score_below_threshold"))
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.regressionSummary.contains("focused_lane_balance kick=4@0.67 snare=1@0.17 hihat_closed=1@0.17"))
    }

    func testComparatorHighlightsFocusedLaneDistributionDrift() {
        let expectation = ChartQualityExpectation(
            difficulty: "prototype",
            noteCountRange: .init(min: 1, max: 16),
            measureCountRange: .init(min: 1, max: 2),
            requiredLanes: [.kick, .snare],
            allowedLanes: [.kick, .snare, .hihatClosed],
            minDistinctLanes: 2,
            maxSimultaneousNotes: 1,
            maxNotesPerBeat: 4,
            maxNotesPerMeasure: 16,
            allowedEmptyMeasures: 0,
            minimumScore: 0.5
        )

        let baseline = ChartQualityEvaluator.evaluate(
            chart: makeChart(
                difficulty: "prototype",
                measures: 1,
                notes: [
                    .init(lane: .kick, tick: 0, beatIndex: 0, startSeconds: 0.0),
                    .init(lane: .hihatClosed, tick: 240, beatIndex: 0, startSeconds: 0.25),
                    .init(lane: .snare, tick: 480, beatIndex: 1, startSeconds: 0.5),
                    .init(lane: .hihatClosed, tick: 720, beatIndex: 1, startSeconds: 0.75)
                ]
            ),
            against: expectation
        )

        let candidate = ChartQualityEvaluator.evaluate(
            chart: makeChart(
                difficulty: "prototype",
                measures: 1,
                notes: [
                    .init(lane: .kick, tick: 0, beatIndex: 0, startSeconds: 0.0),
                    .init(lane: .kick, tick: 120, beatIndex: 0, startSeconds: 0.125),
                    .init(lane: .hihatClosed, tick: 240, beatIndex: 0, startSeconds: 0.25),
                    .init(lane: .hihatClosed, tick: 720, beatIndex: 1, startSeconds: 0.75),
                    .init(lane: .hihatClosed, tick: 840, beatIndex: 1, startSeconds: 0.875),
                    .init(lane: .snare, tick: 960, beatIndex: 2, startSeconds: 1.0)
                ]
            ),
            against: expectation
        )

        let comparison = ChartMetricsComparator.compare(baseline: baseline, candidate: candidate)

        XCTAssertEqual(comparison.noteCountDelta, 2)
        XCTAssertEqual(comparison.measureCountDelta, 0)
        XCTAssertEqual(comparison.averageNotesPerMeasureDelta, 2.0, accuracy: 0.0001)

        let kickDelta = try XCTUnwrap(comparison.focusedLaneDeltas.first(where: { $0.lane == .kick }))
        XCTAssertEqual(kickDelta.baselineNoteCount, 1)
        XCTAssertEqual(kickDelta.candidateNoteCount, 2)
        XCTAssertEqual(kickDelta.noteCountDelta, 1)
        XCTAssertEqual(kickDelta.baselineNoteShare, 0.25, accuracy: 0.0001)
        XCTAssertEqual(kickDelta.candidateNoteShare, 2.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(kickDelta.noteShareDelta, (2.0 / 6.0) - 0.25, accuracy: 0.0001)

        let snareDelta = try XCTUnwrap(comparison.focusedLaneDeltas.first(where: { $0.lane == .snare }))
        XCTAssertEqual(snareDelta.noteCountDelta, 0)
        XCTAssertEqual(snareDelta.noteShareDelta, (1.0 / 6.0) - 0.25, accuracy: 0.0001)

        let hihatDelta = try XCTUnwrap(comparison.focusedLaneDeltas.first(where: { $0.lane == .hihatClosed }))
        XCTAssertEqual(hihatDelta.noteCountDelta, 1)
        XCTAssertEqual(hihatDelta.baselineNoteShare, 0.5, accuracy: 0.0001)
        XCTAssertEqual(hihatDelta.candidateNoteShare, 0.5, accuracy: 0.0001)
        XCTAssertEqual(hihatDelta.noteShareDelta, 0.0, accuracy: 0.0001)
        XCTAssertTrue(comparison.summary.contains("notes=+2"))
        XCTAssertTrue(comparison.summary.contains("kick=+1@+0.08"))
        XCTAssertTrue(comparison.summary.contains("snare=+0@-0.08"))
        XCTAssertTrue(comparison.summary.contains("hihat_closed=+1@+0.00"))
    }

    func testCorpusRunnerProducesStableRegressionFriendlyTextReport() {
        let corpus = ChartEvaluationCorpus(
            songs: [
                ChartEvaluationSong(
                    id: "fixture-song",
                    title: "Fixture Song",
                    sourceFixture: "fixture.wav",
                    sourceType: "real_clip",
                    sourceProvenance: "licensed internal review export",
                    clipDurationSeconds: 1.0,
                    reviewStatus: "approved_baseline",
                    baselineStatus: "approved_baseline",
                    baselineChartID: "chart-baseline-v1",
                    reviewNotes: ["Human-review baseline once real clip arrives."],
                    reviewChecklist: ["Check kick/snare alignment", "Check fill placement"],
                    tags: ["smoke", "regression"],
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
        XCTAssertEqual(report.tagSummaries.map(\.tag), ["regression", "smoke"])
        XCTAssertEqual(report.tagSummaries.map(\.passedExpectations), [1, 1])
        XCTAssertEqual(report.difficultySummaries.map(\.difficulty), ["prototype"])
        XCTAssertEqual(report.difficultySummaries.map(\.passedExpectations), [1])
        XCTAssertEqual(report.sourceTypeSummaries.map(\.key), ["real_clip"])
        XCTAssertEqual(report.reviewStatusSummaries.map(\.key), ["approved_baseline"])
        XCTAssertEqual(report.baselineStatusSummaries.map(\.key), ["approved_baseline"])
        XCTAssertEqual(report.lintIssues.count, 0)

        let text = report.renderText()
        XCTAssertTrue(text.contains("corpus pass=1/1 failed=0 missing=0 tags=2 lint=0"))
        XCTAssertTrue(text.contains("source_summary real_clip=1"))
        XCTAssertTrue(text.contains("review_summary approved_baseline=1"))
        XCTAssertTrue(text.contains("baseline_summary approved_baseline=1"))
        XCTAssertTrue(text.contains("tag_summary regression=1/1 smoke=1/1"))
        XCTAssertTrue(text.contains("difficulty_summary prototype=1/1"))
        XCTAssertTrue(text.contains("fixture-song [prototype] PASS prototype score=1.00"))
        XCTAssertTrue(text.contains("source=fixture.wav"))
        XCTAssertTrue(text.contains("source_type=real_clip"))
        XCTAssertTrue(text.contains("review=approved_baseline"))
        XCTAssertTrue(text.contains("baseline=approved_baseline"))
        XCTAssertTrue(text.contains("baseline_chart=chart-baseline-v1"))
        XCTAssertTrue(text.contains("provenance licensed internal review export"))
        XCTAssertTrue(text.contains("lane_usage kick=1 snare=1"))
        XCTAssertTrue(text.contains("measure_density m0=2"))
        XCTAssertTrue(text.contains("tick=0:beat=0:sub=0:lane=kick:vel=1.00"))
        XCTAssertTrue(text.contains("tick=480:beat=1:sub=4:lane=snare:vel=0.70"))

        let packaged = report.packagedReport()
        XCTAssertEqual(packaged.summary.status, "PASS")
        XCTAssertEqual(packaged.summary.totalExpectations, 1)
        XCTAssertEqual(packaged.summary.passedExpectations, 1)
        XCTAssertEqual(packaged.summary.failedExpectations, 0)
        XCTAssertEqual(packaged.summary.missingChartCount, 0)
        XCTAssertEqual(packaged.summary.lintIssueCount, 0)
        XCTAssertEqual(packaged.summary.topTags, ["regression", "smoke"])
        XCTAssertEqual(packaged.summary.sourceTypes, ["real_clip"])
        XCTAssertEqual(packaged.summary.reviewStates, ["approved_baseline"])
        XCTAssertEqual(packaged.summary.baselineStates, ["approved_baseline"])
        XCTAssertEqual(packaged.text, text)
        XCTAssertEqual(packaged.report.totalExpectations, 1)
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
