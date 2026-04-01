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
    public let maxSimultaneousNotes: Int?
    public let maxNotesPerBeat: Int?

    public init(
        difficulty: String,
        noteCountRange: IntRange? = nil,
        measureCountRange: IntRange? = nil,
        requiredLanes: [DrumLane] = [],
        allowedLanes: [DrumLane]? = nil,
        maxSimultaneousNotes: Int? = nil,
        maxNotesPerBeat: Int? = nil
    ) {
        self.difficulty = difficulty
        self.noteCountRange = noteCountRange
        self.measureCountRange = measureCountRange
        self.requiredLanes = requiredLanes
        self.allowedLanes = allowedLanes
        self.maxSimultaneousNotes = maxSimultaneousNotes
        self.maxNotesPerBeat = maxNotesPerBeat
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

    public init(difficulty: String, score: Double, metrics: ChartQualityMetrics, issues: [ChartQualityIssue]) {
        self.difficulty = difficulty
        self.score = score
        self.metrics = metrics
        self.issues = issues
    }
}

public struct ChartQualityMetrics: Codable, Sendable {
    public let noteCount: Int
    public let measureCount: Int
    public let uniqueLanes: [DrumLane]
    public let maxSimultaneousNotes: Int
    public let maxNotesPerBeat: Int

    public init(
        noteCount: Int,
        measureCount: Int,
        uniqueLanes: [DrumLane],
        maxSimultaneousNotes: Int,
        maxNotesPerBeat: Int
    ) {
        self.noteCount = noteCount
        self.measureCount = measureCount
        self.uniqueLanes = uniqueLanes
        self.maxSimultaneousNotes = maxSimultaneousNotes
        self.maxNotesPerBeat = maxNotesPerBeat
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

        if chart.chart.difficulty != expectation.difficulty {
            issues.append(.init(
                code: "difficulty_mismatch",
                message: "Expected difficulty \(expectation.difficulty) but chart difficulty was \(chart.chart.difficulty)."
            ))
        }

        if let range = expectation.noteCountRange, !range.contains(metrics.noteCount) {
            issues.append(.init(
                code: "note_count_out_of_range",
                message: "Expected note count in \(range.min)...\(range.max) but got \(metrics.noteCount)."
            ))
        }

        if let range = expectation.measureCountRange, !range.contains(metrics.measureCount) {
            issues.append(.init(
                code: "measure_count_out_of_range",
                message: "Expected measure count in \(range.min)...\(range.max) but got \(metrics.measureCount)."
            ))
        }

        let laneSet = Set(metrics.uniqueLanes)
        let missingRequired = expectation.requiredLanes.filter { !laneSet.contains($0) }
        if !missingRequired.isEmpty {
            issues.append(.init(
                code: "missing_required_lanes",
                message: "Missing required lanes: \(missingRequired.map(\.rawValue).sorted().joined(separator: ", "))."
            ))
        }

        if let allowedLanes = expectation.allowedLanes {
            let allowedSet = Set(allowedLanes)
            let unexpectedLanes = metrics.uniqueLanes.filter { !allowedSet.contains($0) }
            if !unexpectedLanes.isEmpty {
                issues.append(.init(
                    code: "unexpected_lanes",
                    message: "Found lanes outside allowed set: \(unexpectedLanes.map(\.rawValue).sorted().joined(separator: ", "))."
                ))
            }
        }

        if let maxSimultaneousNotes = expectation.maxSimultaneousNotes,
           metrics.maxSimultaneousNotes > maxSimultaneousNotes {
            issues.append(.init(
                code: "max_simultaneous_notes_exceeded",
                message: "Expected at most \(maxSimultaneousNotes) simultaneous notes but saw \(metrics.maxSimultaneousNotes)."
            ))
        }

        if let maxNotesPerBeat = expectation.maxNotesPerBeat,
           metrics.maxNotesPerBeat > maxNotesPerBeat {
            issues.append(.init(
                code: "max_notes_per_beat_exceeded",
                message: "Expected at most \(maxNotesPerBeat) notes per beat but saw \(metrics.maxNotesPerBeat)."
            ))
        }

        let score = max(0, 1.0 - (Double(issues.count) * 0.2))
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

        return ChartQualityMetrics(
            noteCount: noteCount,
            measureCount: measureCount,
            uniqueLanes: uniqueLanes,
            maxSimultaneousNotes: maxSimultaneousNotes,
            maxNotesPerBeat: maxNotesPerBeat
        )
    }
}
