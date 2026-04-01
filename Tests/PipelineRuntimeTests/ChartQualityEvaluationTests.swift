import XCTest
@testable import PipelineDomain

final class ChartQualityEvaluationTests: XCTestCase {
    func testCorpusFixtureDecodesAndDescribesMinimalSongSet() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "chart-eval-corpus", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(ChartEvaluationCorpus.self, from: data)

        XCTAssertEqual(corpus.schemaVersion, "1.0.0")
        XCTAssertEqual(corpus.songs.count, 1)

        let song = try XCTUnwrap(corpus.songs.first)
        XCTAssertEqual(song.id, "known-tone")
        XCTAssertEqual(song.sourceFixture, "known-tone.wav")

        let expectation = try XCTUnwrap(song.expectations.first)
        XCTAssertEqual(expectation.difficulty, "easy")
        XCTAssertEqual(expectation.requiredLanes, [.kick])
        XCTAssertEqual(expectation.allowedLanes ?? [], [.kick, .snare, .hihatClosed])
        XCTAssertEqual(expectation.maxSimultaneousNotes, 1)
    }

    func testEvaluatorPassesChartThatFitsFixtureExpectations() {
        let expectation = ChartQualityExpectation(
            difficulty: "easy",
            noteCountRange: .init(min: 2, max: 6),
            measureCountRange: .init(min: 1, max: 2),
            requiredLanes: [.kick, .snare],
            allowedLanes: [.kick, .snare, .hihatClosed],
            maxSimultaneousNotes: 1,
            maxNotesPerBeat: 2
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
        XCTAssertEqual(report.score, 1.0, accuracy: 0.0001)
    }

    func testEvaluatorFlagsOverchartedUnexpectedLaneAndChording() {
        let expectation = ChartQualityExpectation(
            difficulty: "easy",
            noteCountRange: .init(min: 1, max: 4),
            measureCountRange: .init(min: 1, max: 1),
            requiredLanes: [.kick],
            allowedLanes: [.kick, .snare],
            maxSimultaneousNotes: 1,
            maxNotesPerBeat: 2
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

        let codes = Set(report.issues.map(\.code))
        XCTAssertTrue(codes.contains("difficulty_mismatch"))
        XCTAssertTrue(codes.contains("note_count_out_of_range"))
        XCTAssertTrue(codes.contains("measure_count_out_of_range"))
        XCTAssertTrue(codes.contains("unexpected_lanes"))
        XCTAssertTrue(codes.contains("max_simultaneous_notes_exceeded"))
        XCTAssertTrue(codes.contains("max_notes_per_beat_exceeded"))
        XCTAssertLessThan(report.score, 0.01)
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
