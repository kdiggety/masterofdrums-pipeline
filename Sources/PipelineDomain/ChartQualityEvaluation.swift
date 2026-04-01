import Foundation

public struct ChartEvaluationCorpus: Codable, Sendable {
    public let schemaVersion: String
    public let songs: [ChartEvaluationSong]

    public init(schemaVersion: String = "1.0.0", songs: [ChartEvaluationSong]) {
        self.schemaVersion = schemaVersion
        self.songs = songs
    }
}

public struct ChartEvaluationSong: Codable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let sourceFixture: String
    public let notes: String?
    public let expectations: [ChartQualityExpectation]

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        sourceFixture: String,
        notes: String? = nil,
        expectations: [ChartQualityExpectation]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.sourceFixture = sourceFixture
        self.notes = notes
        self.expectations = expectations
    }
}

public struct ChartQualityExpectation: Codable, Sendable {
    public let difficulty: String
    public let noteCountRange: IntRange?
    public let measureCountRange: IntRange?
    public let requiredLanes: [DrumLane]
    public let allowedLanes: [DrumLane]?
    public let minDistinctLanes: Int?
    public let maxSimultaneousNotes: Int?
    public let maxNotesPerBeat: Int?
    public let maxNotesPerMeasure: Int?
    public let allowedEmptyMeasures: Int?
    public let minimumScore: Double?

    public init(
        difficulty: String,
        noteCountRange: IntRange? = nil,
        measureCountRange: IntRange? = nil,
        requiredLanes: [DrumLane] = [],
        allowedLanes: [DrumLane]? = nil,
        minDistinctLanes: Int? = nil,
        maxSimultaneousNotes: Int? = nil,
        maxNotesPerBeat: Int? = nil,
        maxNotesPerMeasure: Int? = nil,
        allowedEmptyMeasures: Int? = nil,
        minimumScore: Double? = nil
    ) {
        self.difficulty = difficulty
        self.noteCountRange = noteCountRange
        self.measureCountRange = measureCountRange
        self.requiredLanes = requiredLanes
        self.allowedLanes = allowedLanes
        self.minDistinctLanes = minDistinctLanes
        self.maxSimultaneousNotes = maxSimultaneousNotes
        self.maxNotesPerBeat = maxNotesPerBeat
        self.maxNotesPerMeasure = maxNotesPerMeasure
        self.allowedEmptyMeasures = allowedEmptyMeasures
        self.minimumScore = minimumScore
    }
}

public struct IntRange: Codable, Sendable {
    public let min: Int
    public let max: Int

    public init(min: Int, max: Int) {
        self.min = min
        self.max = max
    }

    public func contains(_ value: Int) -> Bool {
        value >= min && value <= max
    }
}

public struct ChartQualityReport: Codable, Sendable {
    public let difficulty: String
    public let score: Double
    public let metrics: ChartQualityMetrics
    public let issues: [ChartQualityIssue]

    public var passed: Bool {
        issues.isEmpty
    }

    public var summary: String {
        if passed {
            return "PASS \(difficulty) score=\(Self.format(score)) notes=\(metrics.noteCount) measures=\(metrics.measureCount) lanes=\(metrics.uniqueLanes.map(\.rawValue).joined(separator: ","))"
        }

        return "FAIL \(difficulty) score=\(Self.format(score)) issues=\(issues.map(\.code).joined(separator: ","))"
    }

    public init(difficulty: String, score: Double, metrics: ChartQualityMetrics, issues: [ChartQualityIssue]) {
        self.difficulty = difficulty
        self.score = score
        self.metrics = metrics
        self.issues = issues
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

public struct ChartQualityMetrics: Codable, Sendable {
    public let noteCount: Int
    public let measureCount: Int
    public let uniqueLanes: [DrumLane]
    public let laneUsage: [LaneUsageMetric]
    public let maxSimultaneousNotes: Int
    public let maxNotesPerBeat: Int
    public let maxNotesPerMeasure: Int
    public let emptyMeasureCount: Int
    public let averageNotesPerMeasure: Double

    public init(
        noteCount: Int,
        measureCount: Int,
        uniqueLanes: [DrumLane],
        laneUsage: [LaneUsageMetric],
        maxSimultaneousNotes: Int,
        maxNotesPerBeat: Int,
        maxNotesPerMeasure: Int,
        emptyMeasureCount: Int,
        averageNotesPerMeasure: Double
    ) {
        self.noteCount = noteCount
        self.measureCount = measureCount
        self.uniqueLanes = uniqueLanes
        self.laneUsage = laneUsage
        self.maxSimultaneousNotes = maxSimultaneousNotes
        self.maxNotesPerBeat = maxNotesPerBeat
        self.maxNotesPerMeasure = maxNotesPerMeasure
        self.emptyMeasureCount = emptyMeasureCount
        self.averageNotesPerMeasure = averageNotesPerMeasure
    }
}

public struct LaneUsageMetric: Codable, Sendable {
    public let lane: DrumLane
    public let noteCount: Int

    public init(lane: DrumLane, noteCount: Int) {
        self.lane = lane
        self.noteCount = noteCount
    }
}

public struct ChartQualityIssue: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ChartQualityEvaluator {
    public static func evaluate(chart: BaseChartContract, against expectation: ChartQualityExpectation) -> ChartQualityReport {
        let metrics = collectMetrics(from: chart)
        var issues: [ChartQualityIssue] = []
        var penalty = 0.0

        if chart.chart.difficulty != expectation.difficulty {
            issues.append(.init(
                code: "difficulty_mismatch",
                message: "Expected difficulty \(expectation.difficulty) but chart difficulty was \(chart.chart.difficulty)."
            ))
            penalty += 0.20
        }

        if metrics.noteCount == 0 {
            issues.append(.init(
                code: "empty_chart",
                message: "Chart contains no notes."
            ))
            penalty += 0.45
        }

        if let range = expectation.noteCountRange, !range.contains(metrics.noteCount) {
            issues.append(.init(
                code: "note_count_out_of_range",
                message: "Expected note count in \(range.min)...\(range.max) but got \(metrics.noteCount)."
            ))
            penalty += proportionalPenalty(actual: metrics.noteCount, expectedRange: range, cap: 0.20)
        }

        if let range = expectation.measureCountRange, !range.contains(metrics.measureCount) {
            issues.append(.init(
                code: "measure_count_out_of_range",
                message: "Expected measure count in \(range.min)...\(range.max) but got \(metrics.measureCount)."
            ))
            penalty += proportionalPenalty(actual: metrics.measureCount, expectedRange: range, cap: 0.15)
        }

        let laneSet = Set(metrics.uniqueLanes)
        let missingRequired = expectation.requiredLanes.filter { !laneSet.contains($0) }
        if !missingRequired.isEmpty {
            issues.append(.init(
                code: "missing_required_lanes",
                message: "Missing required lanes: \(missingRequired.map(\.rawValue).sorted().joined(separator: ", "))."
            ))
            penalty += min(0.20, 0.08 * Double(missingRequired.count))
        }

        if let allowedLanes = expectation.allowedLanes {
            let allowedSet = Set(allowedLanes)
            let unexpectedLanes = metrics.uniqueLanes.filter { !allowedSet.contains($0) }
            if !unexpectedLanes.isEmpty {
                issues.append(.init(
                    code: "unexpected_lanes",
                    message: "Found lanes outside allowed set: \(unexpectedLanes.map(\.rawValue).sorted().joined(separator: ", "))."
                ))
                penalty += min(0.20, 0.08 * Double(unexpectedLanes.count))
            }
        }

        if let minDistinctLanes = expectation.minDistinctLanes,
           metrics.uniqueLanes.count < minDistinctLanes {
            issues.append(.init(
                code: "insufficient_lane_variety",
                message: "Expected at least \(minDistinctLanes) distinct lanes but saw \(metrics.uniqueLanes.count)."
            ))
            penalty += min(0.15, 0.07 * Double(minDistinctLanes - metrics.uniqueLanes.count))
        }

        if let maxSimultaneousNotes = expectation.maxSimultaneousNotes,
           metrics.maxSimultaneousNotes > maxSimultaneousNotes {
            issues.append(.init(
                code: "max_simultaneous_notes_exceeded",
                message: "Expected at most \(maxSimultaneousNotes) simultaneous notes but saw \(metrics.maxSimultaneousNotes)."
            ))
            penalty += min(0.20, 0.05 * Double(metrics.maxSimultaneousNotes - maxSimultaneousNotes))
        }

        if let maxNotesPerBeat = expectation.maxNotesPerBeat,
           metrics.maxNotesPerBeat > maxNotesPerBeat {
            issues.append(.init(
                code: "max_notes_per_beat_exceeded",
                message: "Expected at most \(maxNotesPerBeat) notes per beat but saw \(metrics.maxNotesPerBeat)."
            ))
            penalty += min(0.20, 0.04 * Double(metrics.maxNotesPerBeat - maxNotesPerBeat))
        }

        if let maxNotesPerMeasure = expectation.maxNotesPerMeasure,
           metrics.maxNotesPerMeasure > maxNotesPerMeasure {
            issues.append(.init(
                code: "max_notes_per_measure_exceeded",
                message: "Expected at most \(maxNotesPerMeasure) notes in any measure but saw \(metrics.maxNotesPerMeasure)."
            ))
            penalty += min(0.15, 0.03 * Double(metrics.maxNotesPerMeasure - maxNotesPerMeasure))
        }

        if let allowedEmptyMeasures = expectation.allowedEmptyMeasures,
           metrics.emptyMeasureCount > allowedEmptyMeasures {
            issues.append(.init(
                code: "too_many_empty_measures",
                message: "Expected at most \(allowedEmptyMeasures) empty measures but saw \(metrics.emptyMeasureCount)."
            ))
            penalty += min(0.15, 0.05 * Double(metrics.emptyMeasureCount - allowedEmptyMeasures))
        }

        let score = max(0, 1.0 - penalty)
        if let minimumScore = expectation.minimumScore,
           score < minimumScore {
            issues.append(.init(
                code: "score_below_threshold",
                message: "Expected score >= \(String(format: "%.2f", minimumScore)) but got \(String(format: "%.2f", score))."
            ))
        }

        return ChartQualityReport(
            difficulty: chart.chart.difficulty,
            score: score,
            metrics: metrics,
            issues: issues
        )
    }

    private static func collectMetrics(from chart: BaseChartContract) -> ChartQualityMetrics {
        let noteCount = chart.chart.notes.count
        let measureCount = chart.chart.measures.count
        let uniqueLanes = Array(Set(chart.chart.notes.map(\.lane))).sorted { $0.rawValue < $1.rawValue }

        let simultaneousGroups = Dictionary(grouping: chart.chart.notes, by: { $0.tick })
        let maxSimultaneousNotes = simultaneousGroups.values.map(\.count).max() ?? 0

        let notesPerBeat = Dictionary(grouping: chart.chart.notes, by: { $0.beatIndex })
        let maxNotesPerBeat = notesPerBeat.values.map(\.count).max() ?? 0

        let notesPerMeasure = Dictionary(grouping: chart.chart.notes, by: { note in
            measureIndex(for: note.beatIndex, measures: chart.chart.measures)
        })
        let maxNotesPerMeasure = notesPerMeasure.values.map(\.count).max() ?? 0
        let countedMeasures = Set(notesPerMeasure.keys.compactMap { $0 })
        let emptyMeasureCount = max(0, measureCount - countedMeasures.count)
        let averageNotesPerMeasure = measureCount > 0 ? Double(noteCount) / Double(measureCount) : 0

        let laneUsage = Dictionary(grouping: chart.chart.notes, by: \.lane)
            .map { LaneUsageMetric(lane: $0.key, noteCount: $0.value.count) }
            .sorted { $0.lane.rawValue < $1.lane.rawValue }

        return ChartQualityMetrics(
            noteCount: noteCount,
            measureCount: measureCount,
            uniqueLanes: uniqueLanes,
            laneUsage: laneUsage,
            maxSimultaneousNotes: maxSimultaneousNotes,
            maxNotesPerBeat: maxNotesPerBeat,
            maxNotesPerMeasure: maxNotesPerMeasure,
            emptyMeasureCount: emptyMeasureCount,
            averageNotesPerMeasure: averageNotesPerMeasure
        )
    }

    private static func measureIndex(for beatIndex: Int, measures: [BaseChartMeasure]) -> Int? {
        for measure in measures {
            let start = measure.startBeatIndex
            let end = start + measure.beatCount
            if beatIndex >= start && beatIndex < end {
                return measure.barIndex
            }
        }
        return nil
    }

    private static func proportionalPenalty(actual: Int, expectedRange: IntRange, cap: Double) -> Double {
        if expectedRange.contains(actual) {
            return 0
        }

        let delta: Int
        let scale: Int
        if actual < expectedRange.min {
            delta = expectedRange.min - actual
            scale = max(expectedRange.min, 1)
        } else {
            delta = actual - expectedRange.max
            scale = max(expectedRange.max, 1)
        }

        return min(cap, (Double(delta) / Double(scale)) * cap)
    }
}
