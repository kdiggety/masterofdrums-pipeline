import Foundation

public struct ChartEvaluationCorpus: Codable, Sendable {
    public let schemaVersion: String
    public let songs: [ChartEvaluationSong]

    public init(schemaVersion: String = "1.3.0", songs: [ChartEvaluationSong]) {
        self.schemaVersion = schemaVersion
        self.songs = songs
    }
}

public struct ChartEvaluationSong: Codable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let sourceFixture: String
    public let sourceType: String
    public let sourceProvenance: String?
    public let clipDurationSeconds: Double?
    public let reviewStatus: String?
    public let baselineStatus: String?
    public let baselineChartID: String?
    public let notes: String?
    public let reviewNotes: [String]
    public let reviewChecklist: [String]
    public let tags: [String]
    public let expectations: [ChartQualityExpectation]

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        sourceFixture: String,
        sourceType: String = "fixture_audio",
        sourceProvenance: String? = nil,
        clipDurationSeconds: Double? = nil,
        reviewStatus: String? = nil,
        baselineStatus: String? = nil,
        baselineChartID: String? = nil,
        notes: String? = nil,
        reviewNotes: [String] = [],
        reviewChecklist: [String] = [],
        tags: [String] = [],
        expectations: [ChartQualityExpectation]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.sourceFixture = sourceFixture
        self.sourceType = sourceType
        self.sourceProvenance = sourceProvenance
        self.clipDurationSeconds = clipDurationSeconds
        self.reviewStatus = reviewStatus
        self.baselineStatus = baselineStatus
        self.baselineChartID = baselineChartID
        self.notes = notes
        self.reviewNotes = reviewNotes
        self.reviewChecklist = reviewChecklist
        self.tags = tags
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
    public let maxConsecutiveSameLaneNotes: Int?
    public let maxMeasureBurstiness: Double?
    public let allowedEmptyMeasures: Int?
    public let minimumScore: Double?
    public let focusedLaneExpectations: [FocusedLaneExpectation]

    enum CodingKeys: String, CodingKey {
        case difficulty
        case noteCountRange
        case measureCountRange
        case requiredLanes
        case allowedLanes
        case minDistinctLanes
        case maxSimultaneousNotes
        case maxNotesPerBeat
        case maxNotesPerMeasure
        case maxConsecutiveSameLaneNotes
        case maxMeasureBurstiness
        case allowedEmptyMeasures
        case minimumScore
        case focusedLaneExpectations
    }

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
        maxConsecutiveSameLaneNotes: Int? = nil,
        maxMeasureBurstiness: Double? = nil,
        allowedEmptyMeasures: Int? = nil,
        minimumScore: Double? = nil,
        focusedLaneExpectations: [FocusedLaneExpectation] = []
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
        self.maxConsecutiveSameLaneNotes = maxConsecutiveSameLaneNotes
        self.maxMeasureBurstiness = maxMeasureBurstiness
        self.allowedEmptyMeasures = allowedEmptyMeasures
        self.minimumScore = minimumScore
        self.focusedLaneExpectations = focusedLaneExpectations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        difficulty = try container.decode(String.self, forKey: .difficulty)
        noteCountRange = try container.decodeIfPresent(IntRange.self, forKey: .noteCountRange)
        measureCountRange = try container.decodeIfPresent(IntRange.self, forKey: .measureCountRange)
        requiredLanes = try container.decodeIfPresent([DrumLane].self, forKey: .requiredLanes) ?? []
        allowedLanes = try container.decodeIfPresent([DrumLane].self, forKey: .allowedLanes)
        minDistinctLanes = try container.decodeIfPresent(Int.self, forKey: .minDistinctLanes)
        maxSimultaneousNotes = try container.decodeIfPresent(Int.self, forKey: .maxSimultaneousNotes)
        maxNotesPerBeat = try container.decodeIfPresent(Int.self, forKey: .maxNotesPerBeat)
        maxNotesPerMeasure = try container.decodeIfPresent(Int.self, forKey: .maxNotesPerMeasure)
        maxConsecutiveSameLaneNotes = try container.decodeIfPresent(Int.self, forKey: .maxConsecutiveSameLaneNotes)
        maxMeasureBurstiness = try container.decodeIfPresent(Double.self, forKey: .maxMeasureBurstiness)
        allowedEmptyMeasures = try container.decodeIfPresent(Int.self, forKey: .allowedEmptyMeasures)
        minimumScore = try container.decodeIfPresent(Double.self, forKey: .minimumScore)
        focusedLaneExpectations = try container.decodeIfPresent([FocusedLaneExpectation].self, forKey: .focusedLaneExpectations) ?? []
    }
}

public struct FocusedLaneExpectation: Codable, Sendable {
    public let lane: DrumLane
    public let shareRange: DoubleRange?
    public let notesPerMeasureRange: DoubleRange?
    public let minNoteCount: Int?
    public let maxNoteCount: Int?

    public init(
        lane: DrumLane,
        shareRange: DoubleRange? = nil,
        notesPerMeasureRange: DoubleRange? = nil,
        minNoteCount: Int? = nil,
        maxNoteCount: Int? = nil
    ) {
        self.lane = lane
        self.shareRange = shareRange
        self.notesPerMeasureRange = notesPerMeasureRange
        self.minNoteCount = minNoteCount
        self.maxNoteCount = maxNoteCount
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
    public let regressionSnapshot: ChartRegressionSnapshot

    public var passed: Bool {
        issues.isEmpty
    }

    public var summary: String {
        if passed {
            return "PASS \(difficulty) score=\(Self.format(score)) notes=\(metrics.noteCount) measures=\(metrics.measureCount) lanes=\(metrics.uniqueLanes.map(\.rawValue).joined(separator: ","))"
        }

        return "FAIL \(difficulty) score=\(Self.format(score)) issues=\(issues.map(\.code).joined(separator: ","))"
    }

    public var regressionSummary: String {
        let issueText = issues.isEmpty ? "none" : issues.map(\.code).joined(separator: ",")
        let focusedLaneText = regressionSnapshot.focusedLaneBalance.isEmpty
            ? "none"
            : regressionSnapshot.focusedLaneBalance.map { "\($0.lane)=\($0.noteCount)@\(Self.format($0.noteShare))" }.joined(separator: " ")
        return [
            summary,
            "snapshot lanes=\(regressionSnapshot.lanes.joined(separator: ",")) measures=\(regressionSnapshot.measureCount) notes=\(regressionSnapshot.noteCount)",
            "lane_usage \(regressionSnapshot.laneUsage.map { "\($0.lane)=\($0.noteCount)" }.joined(separator: " "))",
            "focused_lane_balance \(focusedLaneText)",
            "measure_density \(regressionSnapshot.measureDensity.map { "m\($0.measureIndex)=\($0.noteCount)" }.joined(separator: " "))",
            "quality_flags same_lane_streak=\(metrics.maxConsecutiveSameLaneNotes) measure_burstiness=\(Self.format(metrics.maxMeasureBurstiness))",
            "note_preview \(regressionSnapshot.notePreview.joined(separator: " | "))",
            "issues \(issueText)"
        ].joined(separator: "\n")
    }

    public init(difficulty: String, score: Double, metrics: ChartQualityMetrics, issues: [ChartQualityIssue], regressionSnapshot: ChartRegressionSnapshot) {
        self.difficulty = difficulty
        self.score = score
        self.metrics = metrics
        self.issues = issues
        self.regressionSnapshot = regressionSnapshot
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
    public let laneBalance: [LaneBalanceMetric]
    public let focusedLaneBalance: [LaneBalanceMetric]
    public let measureDensity: [MeasureDensityMetric]
    public let maxSimultaneousNotes: Int
    public let maxNotesPerBeat: Int
    public let maxNotesPerMeasure: Int
    public let maxConsecutiveSameLaneNotes: Int
    public let maxMeasureBurstiness: Double
    public let emptyMeasureCount: Int
    public let averageNotesPerMeasure: Double

    public init(
        noteCount: Int,
        measureCount: Int,
        uniqueLanes: [DrumLane],
        laneUsage: [LaneUsageMetric],
        laneBalance: [LaneBalanceMetric],
        focusedLaneBalance: [LaneBalanceMetric],
        measureDensity: [MeasureDensityMetric],
        maxSimultaneousNotes: Int,
        maxNotesPerBeat: Int,
        maxNotesPerMeasure: Int,
        maxConsecutiveSameLaneNotes: Int,
        maxMeasureBurstiness: Double,
        emptyMeasureCount: Int,
        averageNotesPerMeasure: Double
    ) {
        self.noteCount = noteCount
        self.measureCount = measureCount
        self.uniqueLanes = uniqueLanes
        self.laneUsage = laneUsage
        self.laneBalance = laneBalance
        self.focusedLaneBalance = focusedLaneBalance
        self.measureDensity = measureDensity
        self.maxSimultaneousNotes = maxSimultaneousNotes
        self.maxNotesPerBeat = maxNotesPerBeat
        self.maxNotesPerMeasure = maxNotesPerMeasure
        self.maxConsecutiveSameLaneNotes = maxConsecutiveSameLaneNotes
        self.maxMeasureBurstiness = maxMeasureBurstiness
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

public struct LaneBalanceMetric: Codable, Sendable {
    public let lane: DrumLane
    public let noteCount: Int
    public let noteShare: Double
    public let notesPerMeasure: Double

    public init(lane: DrumLane, noteCount: Int, noteShare: Double, notesPerMeasure: Double) {
        self.lane = lane
        self.noteCount = noteCount
        self.noteShare = noteShare
        self.notesPerMeasure = notesPerMeasure
    }
}

public struct MeasureDensityMetric: Codable, Sendable {
    public let measureIndex: Int
    public let noteCount: Int

    public init(measureIndex: Int, noteCount: Int) {
        self.measureIndex = measureIndex
        self.noteCount = noteCount
    }
}

public struct ChartRegressionSnapshot: Codable, Sendable {
    public let measureCount: Int
    public let noteCount: Int
    public let lanes: [String]
    public let laneUsage: [ChartRegressionLaneUsage]
    public let focusedLaneBalance: [ChartRegressionLaneBalance]
    public let measureDensity: [ChartRegressionMeasureDensity]
    public let notePreview: [String]

    public init(measureCount: Int, noteCount: Int, lanes: [String], laneUsage: [ChartRegressionLaneUsage], focusedLaneBalance: [ChartRegressionLaneBalance], measureDensity: [ChartRegressionMeasureDensity], notePreview: [String]) {
        self.measureCount = measureCount
        self.noteCount = noteCount
        self.lanes = lanes
        self.laneUsage = laneUsage
        self.focusedLaneBalance = focusedLaneBalance
        self.measureDensity = measureDensity
        self.notePreview = notePreview
    }
}

public struct ChartRegressionLaneUsage: Codable, Sendable {
    public let lane: String
    public let noteCount: Int

    public init(lane: String, noteCount: Int) {
        self.lane = lane
        self.noteCount = noteCount
    }
}

public struct ChartRegressionLaneBalance: Codable, Sendable {
    public let lane: String
    public let noteCount: Int
    public let noteShare: Double

    public init(lane: String, noteCount: Int, noteShare: Double) {
        self.lane = lane
        self.noteCount = noteCount
        self.noteShare = noteShare
    }
}

public struct ChartRegressionMeasureDensity: Codable, Sendable {
    public let measureIndex: Int
    public let noteCount: Int

    public init(measureIndex: Int, noteCount: Int) {
        self.measureIndex = measureIndex
        self.noteCount = noteCount
    }
}

public struct DoubleRange: Codable, Sendable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    public func contains(_ value: Double) -> Bool {
        value >= min && value <= max
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

public struct ChartEvaluationLintIssue: Codable, Sendable {
    public let severity: String
    public let code: String
    public let songID: String?
    public let message: String

    public init(severity: String, code: String, songID: String? = nil, message: String) {
        self.severity = severity
        self.code = code
        self.songID = songID
        self.message = message
    }
}

public struct ChartEvaluationResult: Codable, Sendable {
    public let songID: String
    public let songTitle: String
    public let sourceFixture: String
    public let sourceType: String
    public let sourceProvenance: String?
    public let clipDurationSeconds: Double?
    public let songTags: [String]
    public let reviewStatus: String?
    public let baselineStatus: String?
    public let baselineChartID: String?
    public let report: ChartQualityReport
    public let expectation: ChartQualityExpectation
    public let comparison: ChartMetricsComparison?

    public var summaryLine: String {
        let durationText = clipDurationSeconds.map { String(format: "%.2fs", $0) } ?? "unknown"
        let tagText = songTags.isEmpty ? "-" : songTags.joined(separator: ",")
        let reviewText = reviewStatus ?? "unspecified"
        let baselineText = baselineStatus ?? "unspecified"
        let baselineChartText = baselineChartID ?? "none"
        return "\(songID) [\(expectation.difficulty)] \(report.summary) source=\(sourceFixture) source_type=\(sourceType) duration=\(durationText) tags=\(tagText) review=\(reviewText) baseline=\(baselineText) baseline_chart=\(baselineChartText)"
    }

    public var provenanceLine: String? {
        sourceProvenance.map { "provenance \($0)" }
    }

    public init(
        songID: String,
        songTitle: String,
        sourceFixture: String,
        sourceType: String,
        sourceProvenance: String?,
        clipDurationSeconds: Double?,
        songTags: [String],
        reviewStatus: String?,
        baselineStatus: String?,
        baselineChartID: String?,
        expectation: ChartQualityExpectation,
        report: ChartQualityReport,
        comparison: ChartMetricsComparison? = nil
    ) {
        self.songID = songID
        self.songTitle = songTitle
        self.sourceFixture = sourceFixture
        self.sourceType = sourceType
        self.sourceProvenance = sourceProvenance
        self.clipDurationSeconds = clipDurationSeconds
        self.songTags = songTags
        self.reviewStatus = reviewStatus
        self.baselineStatus = baselineStatus
        self.baselineChartID = baselineChartID
        self.expectation = expectation
        self.report = report
        self.comparison = comparison
    }
}

public struct CorpusTagSummary: Codable, Sendable {
    public let tag: String
    public let totalExpectations: Int
    public let passedExpectations: Int
    public let failedExpectations: Int

    public init(tag: String, totalExpectations: Int, passedExpectations: Int, failedExpectations: Int) {
        self.tag = tag
        self.totalExpectations = totalExpectations
        self.passedExpectations = passedExpectations
        self.failedExpectations = failedExpectations
    }
}

public struct CorpusDifficultySummary: Codable, Sendable {
    public let difficulty: String
    public let totalExpectations: Int
    public let passedExpectations: Int
    public let failedExpectations: Int
    public let missingExpectations: Int

    public init(difficulty: String, totalExpectations: Int, passedExpectations: Int, failedExpectations: Int, missingExpectations: Int) {
        self.difficulty = difficulty
        self.totalExpectations = totalExpectations
        self.passedExpectations = passedExpectations
        self.failedExpectations = failedExpectations
        self.missingExpectations = missingExpectations
    }
}

public struct CorpusValueSummary: Codable, Sendable {
    public let key: String
    public let count: Int

    public init(key: String, count: Int) {
        self.key = key
        self.count = count
    }
}

public struct ChartEvaluationCorpusOperatorSummary: Codable, Sendable {
    public let schemaVersion: String
    public let generatedAt: Date
    public let status: String
    public let totalExpectations: Int
    public let passedExpectations: Int
    public let failedExpectations: Int
    public let missingChartCount: Int
    public let lintIssueCount: Int
    public let comparisonCount: Int
    public let severeRegressionCount: Int
    public let missingCharts: [String]
    public let topTags: [String]
    public let sourceTypes: [String]
    public let reviewStates: [String]
    public let baselineStates: [String]
    public let comparisonStates: [String]

    public init(
        schemaVersion: String,
        generatedAt: Date,
        status: String,
        totalExpectations: Int,
        passedExpectations: Int,
        failedExpectations: Int,
        missingChartCount: Int,
        lintIssueCount: Int,
        comparisonCount: Int,
        severeRegressionCount: Int,
        missingCharts: [String],
        topTags: [String],
        sourceTypes: [String],
        reviewStates: [String],
        baselineStates: [String],
        comparisonStates: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.status = status
        self.totalExpectations = totalExpectations
        self.passedExpectations = passedExpectations
        self.failedExpectations = failedExpectations
        self.missingChartCount = missingChartCount
        self.lintIssueCount = lintIssueCount
        self.comparisonCount = comparisonCount
        self.severeRegressionCount = severeRegressionCount
        self.missingCharts = missingCharts
        self.topTags = topTags
        self.sourceTypes = sourceTypes
        self.reviewStates = reviewStates
        self.baselineStates = baselineStates
        self.comparisonStates = comparisonStates
    }
}

public struct ChartEvaluationCorpusPackagedReport: Codable, Sendable {
    public let summary: ChartEvaluationCorpusOperatorSummary
    public let text: String
    public let report: ChartEvaluationCorpusReport

    public init(summary: ChartEvaluationCorpusOperatorSummary, text: String, report: ChartEvaluationCorpusReport) {
        self.summary = summary
        self.text = text
        self.report = report
    }
}

public struct ChartEvaluationCorpusReport: Codable, Sendable {
    public let schemaVersion: String
    public let generatedAt: Date
    public let totalExpectations: Int
    public let passedExpectations: Int
    public let failedExpectations: Int
    public let results: [ChartEvaluationResult]
    public let missingCharts: [String]
    public let comparisonCount: Int
    public let severeRegressionCount: Int
    public let comparisonStatusSummaries: [CorpusValueSummary]
    public let tagSummaries: [CorpusTagSummary]
    public let difficultySummaries: [CorpusDifficultySummary]
    public let sourceTypeSummaries: [CorpusValueSummary]
    public let reviewStatusSummaries: [CorpusValueSummary]
    public let baselineStatusSummaries: [CorpusValueSummary]
    public let lintIssues: [ChartEvaluationLintIssue]

    public var passed: Bool {
        failedExpectations == 0 && missingCharts.isEmpty && !lintIssues.contains { $0.severity == "error" }
    }

    public var summary: String {
        "corpus pass=\(passedExpectations)/\(totalExpectations) failed=\(failedExpectations) missing=\(missingCharts.count) comparisons=\(comparisonCount) tags=\(tagSummaries.count) lint=\(lintIssues.count)"
    }

    public var operatorSummary: ChartEvaluationCorpusOperatorSummary {
        ChartEvaluationCorpusOperatorSummary(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            status: passed ? "PASS" : "FAIL",
            totalExpectations: totalExpectations,
            passedExpectations: passedExpectations,
            failedExpectations: failedExpectations,
            missingChartCount: missingCharts.count,
            lintIssueCount: lintIssues.count,
            comparisonCount: comparisonCount,
            severeRegressionCount: severeRegressionCount,
            missingCharts: missingCharts,
            topTags: tagSummaries.map(\.tag),
            sourceTypes: sourceTypeSummaries.map(\.key),
            reviewStates: reviewStatusSummaries.map(\.key),
            baselineStates: baselineStatusSummaries.map(\.key),
            comparisonStates: comparisonStatusSummaries.map(\.key)
        )
    }

    public func packagedReport() -> ChartEvaluationCorpusPackagedReport {
        ChartEvaluationCorpusPackagedReport(summary: operatorSummary, text: renderText(), report: self)
    }

    public func renderText() -> String {
        var lines = [summary]
        if !sourceTypeSummaries.isEmpty {
            lines.append("source_summary " + sourceTypeSummaries.map { "\($0.key)=\($0.count)" }.joined(separator: " "))
        }
        if !reviewStatusSummaries.isEmpty {
            lines.append("review_summary " + reviewStatusSummaries.map { "\($0.key)=\($0.count)" }.joined(separator: " "))
        }
        if !baselineStatusSummaries.isEmpty {
            lines.append("baseline_summary " + baselineStatusSummaries.map { "\($0.key)=\($0.count)" }.joined(separator: " "))
        }
        if !comparisonStatusSummaries.isEmpty {
            lines.append("comparison_summary " + comparisonStatusSummaries.map { "\($0.key)=\($0.count)" }.joined(separator: " ") + " severe=\(severeRegressionCount)")
        }
        if !tagSummaries.isEmpty {
            lines.append("tag_summary " + tagSummaries.map { "\($0.tag)=\($0.passedExpectations)/\($0.totalExpectations)" }.joined(separator: " "))
        }
        if !difficultySummaries.isEmpty {
            lines.append("difficulty_summary " + difficultySummaries.map { summary in
                let failureText = summary.failedExpectations > 0 ? "/fail=\(summary.failedExpectations)" : ""
                let missingText = summary.missingExpectations > 0 ? "/missing=\(summary.missingExpectations)" : ""
                return "\(summary.difficulty)=\(summary.passedExpectations)/\(summary.totalExpectations)\(failureText)\(missingText)"
            }.joined(separator: " "))
        }
        if !lintIssues.isEmpty {
            for issue in lintIssues {
                let songText = issue.songID.map { " song=\($0)" } ?? ""
                lines.append("lint severity=\(issue.severity) code=\(issue.code)\(songText) message=\(issue.message)")
            }
        }
        for result in results {
            lines.append(result.summaryLine)
            if let provenanceLine = result.provenanceLine {
                lines.append(provenanceLine)
            }
            if let comparison = result.comparison {
                lines.append(comparison.summary)
            }
            lines.append(result.report.regressionSummary)
        }
        if !missingCharts.isEmpty {
            lines.append("missing " + missingCharts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public init(
        schemaVersion: String,
        generatedAt: Date,
        totalExpectations: Int,
        passedExpectations: Int,
        failedExpectations: Int,
        results: [ChartEvaluationResult],
        missingCharts: [String],
        comparisonCount: Int,
        severeRegressionCount: Int,
        comparisonStatusSummaries: [CorpusValueSummary],
        tagSummaries: [CorpusTagSummary],
        difficultySummaries: [CorpusDifficultySummary],
        sourceTypeSummaries: [CorpusValueSummary],
        reviewStatusSummaries: [CorpusValueSummary],
        baselineStatusSummaries: [CorpusValueSummary],
        lintIssues: [ChartEvaluationLintIssue]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.totalExpectations = totalExpectations
        self.passedExpectations = passedExpectations
        self.failedExpectations = failedExpectations
        self.results = results
        self.missingCharts = missingCharts
        self.comparisonCount = comparisonCount
        self.severeRegressionCount = severeRegressionCount
        self.comparisonStatusSummaries = comparisonStatusSummaries
        self.tagSummaries = tagSummaries
        self.difficultySummaries = difficultySummaries
        self.sourceTypeSummaries = sourceTypeSummaries
        self.reviewStatusSummaries = reviewStatusSummaries
        self.baselineStatusSummaries = baselineStatusSummaries
        self.lintIssues = lintIssues
    }
}

public enum ChartEvaluationCorpusLinter {
    public static func lint(_ corpus: ChartEvaluationCorpus) -> [ChartEvaluationLintIssue] {
        var issues: [ChartEvaluationLintIssue] = []
        var seenSongIDs = Set<String>()

        for song in corpus.songs {
            if !seenSongIDs.insert(song.id).inserted {
                issues.append(.init(severity: "error", code: "duplicate_song_id", songID: song.id, message: "Song IDs must be unique within the corpus."))
            }

            var seenDifficulties = Set<String>()
            for expectation in song.expectations {
                if !seenDifficulties.insert(expectation.difficulty).inserted {
                    issues.append(.init(severity: "error", code: "duplicate_expectation_difficulty", songID: song.id, message: "Each song should only define one expectation per difficulty."))
                }
            }

            if song.expectations.isEmpty {
                issues.append(.init(severity: "warning", code: "missing_expectations", songID: song.id, message: "Song has no expectations yet."))
            }

            if song.sourceType == "real_clip" {
                if (song.sourceProvenance ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(severity: "warning", code: "missing_source_provenance", songID: song.id, message: "Real clips should record where the review audio came from."))
                }
                if (song.reviewStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(severity: "warning", code: "missing_review_status", songID: song.id, message: "Real clips should declare a review status."))
                }
                if song.reviewNotes.isEmpty {
                    issues.append(.init(severity: "warning", code: "missing_review_notes", songID: song.id, message: "Real clips should include review notes for human reviewers."))
                }
                if song.reviewChecklist.isEmpty {
                    issues.append(.init(severity: "warning", code: "missing_review_checklist", songID: song.id, message: "Real clips should include a review checklist for regression signoff."))
                }
                if !song.tags.contains("regression") && !song.tags.contains("smoke") {
                    issues.append(.init(severity: "warning", code: "missing_execution_tag", songID: song.id, message: "Real clips should be tagged for at least one execution lane such as smoke or regression."))
                }
            }

            if song.baselineStatus == "approved_baseline" && (song.baselineChartID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: "warning", code: "missing_baseline_chart_id", songID: song.id, message: "Approved baselines should record the chart artifact or snapshot ID they were approved against."))
            }
        }

        return issues.sorted {
            let lhsSong = $0.songID ?? ""
            let rhsSong = $1.songID ?? ""
            if lhsSong == rhsSong { return $0.code < $1.code }
            return lhsSong < rhsSong
        }
    }
}

public enum ChartEvaluationRunner {
    public static func evaluate(
        corpus: ChartEvaluationCorpus,
        generatedCharts: [String: [String: BaseChartContract]],
        baselineCharts: [String: [String: BaseChartContract]] = [:],
        generatedAt: Date = Date()
    ) -> ChartEvaluationCorpusReport {
        var results: [ChartEvaluationResult] = []
        var missingCharts: [String] = []
        var comparisonCount = 0
        var tagStats: [String: (total: Int, passed: Int)] = [:]
        var difficultyStats: [String: (total: Int, passed: Int, missing: Int)] = [:]
        let lintIssues = ChartEvaluationCorpusLinter.lint(corpus)

        for song in corpus.songs {
            let chartsForSong = generatedCharts[song.id] ?? [:]
            let baselineChartsForSong = baselineCharts[song.id] ?? [:]
            for expectation in song.expectations {
                for tag in song.tags {
                    let current = tagStats[tag] ?? (0, 0)
                    tagStats[tag] = (current.total + 1, current.passed)
                }
                let difficultyCurrent = difficultyStats[expectation.difficulty] ?? (0, 0, 0)
                difficultyStats[expectation.difficulty] = (difficultyCurrent.total + 1, difficultyCurrent.passed, difficultyCurrent.missing)

                guard let chart = chartsForSong[expectation.difficulty] else {
                    missingCharts.append("\(song.id):\(expectation.difficulty)")
                    let missingCurrent = difficultyStats[expectation.difficulty] ?? (0, 0, 0)
                    difficultyStats[expectation.difficulty] = (missingCurrent.total, missingCurrent.passed, missingCurrent.missing + 1)
                    continue
                }
                let report = ChartQualityEvaluator.evaluate(chart: chart, against: expectation)
                let comparison = baselineChartsForSong[expectation.difficulty].map {
                    let baselineReport = ChartQualityEvaluator.evaluate(chart: $0, against: expectation)
                    return ChartMetricsComparator.compare(baseline: baselineReport, candidate: report)
                }
                if comparison != nil {
                    comparisonCount += 1
                }
                if report.passed {
                    for tag in song.tags {
                        let current = tagStats[tag] ?? (0, 0)
                        tagStats[tag] = (current.total, current.passed + 1)
                    }
                    let current = difficultyStats[expectation.difficulty] ?? (0, 0, 0)
                    difficultyStats[expectation.difficulty] = (current.total, current.passed + 1, current.missing)
                }
                results.append(
                    ChartEvaluationResult(
                        songID: song.id,
                        songTitle: song.title,
                        sourceFixture: song.sourceFixture,
                        sourceType: song.sourceType,
                        sourceProvenance: song.sourceProvenance,
                        clipDurationSeconds: song.clipDurationSeconds,
                        songTags: song.tags,
                        reviewStatus: song.reviewStatus,
                        baselineStatus: song.baselineStatus,
                        baselineChartID: song.baselineChartID,
                        expectation: expectation,
                        report: report,
                        comparison: comparison
                    )
                )
            }
        }

        let passedExpectations = results.filter { $0.report.passed }.count
        let failedExpectations = results.count - passedExpectations + missingCharts.count
        let totalExpectations = corpus.songs.reduce(0) { $0 + $1.expectations.count }
        let comparisonStatuses = results.compactMap { $0.comparison?.status }
        let severeRegressionCount = results.filter { $0.comparison?.status == "regressed" }.count
        let tagSummaries = tagStats.keys.sorted().map { tag in
            let stats = tagStats[tag] ?? (0, 0)
            return CorpusTagSummary(
                tag: tag,
                totalExpectations: stats.total,
                passedExpectations: stats.passed,
                failedExpectations: stats.total - stats.passed
            )
        }
        let difficultySummaries = difficultyStats.keys.sorted().map { difficulty in
            let stats = difficultyStats[difficulty] ?? (0, 0, 0)
            return CorpusDifficultySummary(
                difficulty: difficulty,
                totalExpectations: stats.total,
                passedExpectations: stats.passed,
                failedExpectations: max(stats.total - stats.passed - stats.missing, 0),
                missingExpectations: stats.missing
            )
        }

        return ChartEvaluationCorpusReport(
            schemaVersion: corpus.schemaVersion,
            generatedAt: generatedAt,
            totalExpectations: totalExpectations,
            passedExpectations: passedExpectations,
            failedExpectations: failedExpectations,
            results: results,
            missingCharts: missingCharts.sorted(),
            comparisonCount: comparisonCount,
            severeRegressionCount: severeRegressionCount,
            comparisonStatusSummaries: summarizeValues(comparisonStatuses),
            tagSummaries: tagSummaries,
            difficultySummaries: difficultySummaries,
            sourceTypeSummaries: summarizeValues(corpus.songs.map(\.sourceType)),
            reviewStatusSummaries: summarizeValues(corpus.songs.map { $0.reviewStatus ?? "unspecified" }),
            baselineStatusSummaries: summarizeValues(corpus.songs.map { $0.baselineStatus ?? "unspecified" }),
            lintIssues: lintIssues
        )
    }

    private static func summarizeValues(_ values: [String]) -> [CorpusValueSummary] {
        Dictionary(grouping: values, by: { $0 })
            .map { CorpusValueSummary(key: $0.key, count: $0.value.count) }
            .sorted { $0.key < $1.key }
    }
}

public struct ChartMetricsComparison: Codable, Sendable {
    public let baselineDifficulty: String
    public let candidateDifficulty: String
    public let baselinePassed: Bool
    public let candidatePassed: Bool
    public let scoreDelta: Double
    public let noteCountDelta: Int
    public let measureCountDelta: Int
    public let averageNotesPerMeasureDelta: Double
    public let focusedLaneDeltas: [FocusedLaneDelta]
    public let previewAdded: [String]
    public let previewRemoved: [String]
    public let status: String
    public let highlights: [String]

    public var summary: String {
        let laneText = focusedLaneDeltas.isEmpty
            ? "none"
            : focusedLaneDeltas.map {
                let noteDelta = $0.noteCountDelta >= 0 ? "+\($0.noteCountDelta)" : "\($0.noteCountDelta)"
                let shareDelta = $0.noteShareDelta >= 0 ? "+\(Self.format($0.noteShareDelta))" : Self.format($0.noteShareDelta)
                return "\($0.lane.rawValue)=\(noteDelta)@\(shareDelta)"
            }.joined(separator: " ")
        let noteDelta = noteCountDelta >= 0 ? "+\(noteCountDelta)" : "\(noteCountDelta)"
        let measureDelta = measureCountDelta >= 0 ? "+\(measureCountDelta)" : "\(measureCountDelta)"
        let densityDelta = averageNotesPerMeasureDelta >= 0 ? "+\(Self.format(averageNotesPerMeasureDelta))" : Self.format(averageNotesPerMeasureDelta)
        let scoreDeltaText = scoreDelta >= 0 ? "+\(Self.format(scoreDelta))" : Self.format(scoreDelta)
        let previewAddedText = previewAdded.isEmpty ? "none" : previewAdded.joined(separator: " | ")
        let previewRemovedText = previewRemoved.isEmpty ? "none" : previewRemoved.joined(separator: " | ")
        let highlightText = highlights.isEmpty ? "none" : highlights.joined(separator: "; ")
        return "compare status=\(status) baseline=\(baselineDifficulty) candidate=\(candidateDifficulty) pass=\(baselinePassed)->\(candidatePassed) score=\(scoreDeltaText) notes=\(noteDelta) measures=\(measureDelta) avg_notes_per_measure=\(densityDelta) focused=\(laneText) highlights=\(highlightText) preview_added=\(previewAddedText) preview_removed=\(previewRemovedText)"
    }

    public init(
        baselineDifficulty: String,
        candidateDifficulty: String,
        baselinePassed: Bool,
        candidatePassed: Bool,
        scoreDelta: Double,
        noteCountDelta: Int,
        measureCountDelta: Int,
        averageNotesPerMeasureDelta: Double,
        focusedLaneDeltas: [FocusedLaneDelta],
        previewAdded: [String],
        previewRemoved: [String],
        status: String,
        highlights: [String]
    ) {
        self.baselineDifficulty = baselineDifficulty
        self.candidateDifficulty = candidateDifficulty
        self.baselinePassed = baselinePassed
        self.candidatePassed = candidatePassed
        self.scoreDelta = scoreDelta
        self.noteCountDelta = noteCountDelta
        self.measureCountDelta = measureCountDelta
        self.averageNotesPerMeasureDelta = averageNotesPerMeasureDelta
        self.focusedLaneDeltas = focusedLaneDeltas
        self.previewAdded = previewAdded
        self.previewRemoved = previewRemoved
        self.status = status
        self.highlights = highlights
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

public struct FocusedLaneDelta: Codable, Sendable {
    public let lane: DrumLane
    public let baselineNoteCount: Int
    public let candidateNoteCount: Int
    public let noteCountDelta: Int
    public let baselineNoteShare: Double
    public let candidateNoteShare: Double
    public let noteShareDelta: Double

    public init(
        lane: DrumLane,
        baselineNoteCount: Int,
        candidateNoteCount: Int,
        noteCountDelta: Int,
        baselineNoteShare: Double,
        candidateNoteShare: Double,
        noteShareDelta: Double
    ) {
        self.lane = lane
        self.baselineNoteCount = baselineNoteCount
        self.candidateNoteCount = candidateNoteCount
        self.noteCountDelta = noteCountDelta
        self.baselineNoteShare = baselineNoteShare
        self.candidateNoteShare = candidateNoteShare
        self.noteShareDelta = noteShareDelta
    }
}

public enum ChartMetricsComparator {
    private static let focusedLanes: [DrumLane] = [.kick, .snare, .hihatClosed]

    public static func compare(baseline: ChartQualityReport, candidate: ChartQualityReport) -> ChartMetricsComparison {
        let baselineFocused = Dictionary(uniqueKeysWithValues: baseline.metrics.focusedLaneBalance.map { ($0.lane, $0) })
        let candidateFocused = Dictionary(uniqueKeysWithValues: candidate.metrics.focusedLaneBalance.map { ($0.lane, $0) })

        let focusedLaneDeltas = focusedLanes.map { lane in
            let baselineMetric = baselineFocused[lane] ?? LaneBalanceMetric(lane: lane, noteCount: 0, noteShare: 0, notesPerMeasure: 0)
            let candidateMetric = candidateFocused[lane] ?? LaneBalanceMetric(lane: lane, noteCount: 0, noteShare: 0, notesPerMeasure: 0)
            return FocusedLaneDelta(
                lane: lane,
                baselineNoteCount: baselineMetric.noteCount,
                candidateNoteCount: candidateMetric.noteCount,
                noteCountDelta: candidateMetric.noteCount - baselineMetric.noteCount,
                baselineNoteShare: baselineMetric.noteShare,
                candidateNoteShare: candidateMetric.noteShare,
                noteShareDelta: candidateMetric.noteShare - baselineMetric.noteShare
            )
        }

        let baselinePreview = Set(baseline.regressionSnapshot.notePreview)
        let candidatePreview = Set(candidate.regressionSnapshot.notePreview)
        let previewAdded = candidatePreview.subtracting(baselinePreview).sorted()
        let previewRemoved = baselinePreview.subtracting(candidatePreview).sorted()
        let noteCountDelta = candidate.metrics.noteCount - baseline.metrics.noteCount
        let measureCountDelta = candidate.metrics.measureCount - baseline.metrics.measureCount
        let averageNotesPerMeasureDelta = candidate.metrics.averageNotesPerMeasure - baseline.metrics.averageNotesPerMeasure
        let scoreDelta = candidate.score - baseline.score
        let assessment = assess(
            baseline: baseline,
            candidate: candidate,
            noteCountDelta: noteCountDelta,
            averageNotesPerMeasureDelta: averageNotesPerMeasureDelta,
            focusedLaneDeltas: focusedLaneDeltas,
            previewAdded: previewAdded,
            previewRemoved: previewRemoved,
            scoreDelta: scoreDelta
        )

        return ChartMetricsComparison(
            baselineDifficulty: baseline.difficulty,
            candidateDifficulty: candidate.difficulty,
            baselinePassed: baseline.passed,
            candidatePassed: candidate.passed,
            scoreDelta: scoreDelta,
            noteCountDelta: noteCountDelta,
            measureCountDelta: measureCountDelta,
            averageNotesPerMeasureDelta: averageNotesPerMeasureDelta,
            focusedLaneDeltas: focusedLaneDeltas,
            previewAdded: previewAdded,
            previewRemoved: previewRemoved,
            status: assessment.status,
            highlights: assessment.highlights
        )
    }

    private static func assess(
        baseline: ChartQualityReport,
        candidate: ChartQualityReport,
        noteCountDelta: Int,
        averageNotesPerMeasureDelta: Double,
        focusedLaneDeltas: [FocusedLaneDelta],
        previewAdded: [String],
        previewRemoved: [String],
        scoreDelta: Double
    ) -> (status: String, highlights: [String]) {
        if baseline.passed && !candidate.passed {
            let issues = candidate.issues.map(\.code).joined(separator: ",")
            return ("regressed", ["baseline passed but candidate failed", issues.isEmpty ? "candidate introduced new quality failures" : "candidate issues=\(issues)"])
        }
        if !baseline.passed && candidate.passed {
            return ("improved", ["baseline failed but candidate passed", "score_delta=\(format(scoreDelta))"])
        }

        var watchReasons: [String] = []
        var regressReasons: [String] = []
        var improveReasons: [String] = []

        if scoreDelta <= -0.15 {
            regressReasons.append("score_drop=\(format(scoreDelta))")
        } else if scoreDelta <= -0.05 {
            watchReasons.append("score_drop=\(format(scoreDelta))")
        } else if scoreDelta >= 0.10 {
            improveReasons.append("score_gain=+\(format(scoreDelta))")
        }

        let noteDriftRatio = abs(Double(noteCountDelta)) / Double(max(baseline.metrics.noteCount, 1))
        if noteDriftRatio >= 0.35 {
            regressReasons.append("note_drift=\(signed(noteCountDelta)) (\(format(noteDriftRatio * 100))%)")
        } else if noteDriftRatio >= 0.18 {
            watchReasons.append("note_drift=\(signed(noteCountDelta)) (\(format(noteDriftRatio * 100))%)")
        }

        let densityDrift = abs(averageNotesPerMeasureDelta)
        if densityDrift >= 1.5 {
            regressReasons.append("density_shift=\(signed(averageNotesPerMeasureDelta))")
        } else if densityDrift >= 0.75 {
            watchReasons.append("density_shift=\(signed(averageNotesPerMeasureDelta))")
        }

        let maxShareDelta = focusedLaneDeltas.map { abs($0.noteShareDelta) }.max() ?? 0
        if let biggestLane = focusedLaneDeltas.max(by: { abs($0.noteShareDelta) < abs($1.noteShareDelta) }) {
            if maxShareDelta >= 0.18 {
                regressReasons.append("focused_lane_shift=\(biggestLane.lane.rawValue)@\(signed(biggestLane.noteShareDelta))")
            } else if maxShareDelta >= 0.08 {
                watchReasons.append("focused_lane_shift=\(biggestLane.lane.rawValue)@\(signed(biggestLane.noteShareDelta))")
            }
        }

        let previewChurn = previewAdded.count + previewRemoved.count
        if previewChurn >= 8 {
            regressReasons.append("preview_churn=\(previewChurn)")
        } else if previewChurn >= 4 {
            watchReasons.append("preview_churn=\(previewChurn)")
        }

        if !regressReasons.isEmpty {
            return ("regressed", regressReasons)
        }
        if !watchReasons.isEmpty {
            return ("watch", watchReasons)
        }
        if !improveReasons.isEmpty {
            return ("improved", improveReasons)
        }
        return ("stable", ["within_regression_thresholds"])
    }

    private static func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }

    private static func signed(_ value: Double) -> String {
        value >= 0 ? "+\(format(value))" : format(value)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

public enum ChartQualityEvaluator {
    private static let focusedLanes: [DrumLane] = [.kick, .snare, .hihatClosed]

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

        if let maxConsecutiveSameLaneNotes = expectation.maxConsecutiveSameLaneNotes,
           metrics.maxConsecutiveSameLaneNotes > maxConsecutiveSameLaneNotes {
            issues.append(.init(
                code: "same_lane_streak_too_long",
                message: "Expected at most \(maxConsecutiveSameLaneNotes) consecutive notes on the same lane but saw \(metrics.maxConsecutiveSameLaneNotes)."
            ))
            penalty += min(0.15, 0.04 * Double(metrics.maxConsecutiveSameLaneNotes - maxConsecutiveSameLaneNotes))
        }

        if let maxMeasureBurstiness = expectation.maxMeasureBurstiness,
           metrics.maxMeasureBurstiness > maxMeasureBurstiness {
            issues.append(.init(
                code: "measure_burstiness_too_high",
                message: "Expected measure burstiness <= \(format(maxMeasureBurstiness)) but saw \(format(metrics.maxMeasureBurstiness))."
            ))
            penalty += proportionalPenalty(actual: metrics.maxMeasureBurstiness, expectedRange: DoubleRange(min: 0, max: maxMeasureBurstiness), cap: 0.15)
        }

        if let allowedEmptyMeasures = expectation.allowedEmptyMeasures,
           metrics.emptyMeasureCount > allowedEmptyMeasures {
            issues.append(.init(
                code: "too_many_empty_measures",
                message: "Expected at most \(allowedEmptyMeasures) empty measures but saw \(metrics.emptyMeasureCount)."
            ))
            penalty += min(0.15, 0.05 * Double(metrics.emptyMeasureCount - allowedEmptyMeasures))
        }

        let focusedMetrics = Dictionary(uniqueKeysWithValues: metrics.focusedLaneBalance.map { ($0.lane, $0) })
        for focusedExpectation in expectation.focusedLaneExpectations {
            let metric = focusedMetrics[focusedExpectation.lane] ?? LaneBalanceMetric(lane: focusedExpectation.lane, noteCount: 0, noteShare: 0, notesPerMeasure: 0)

            if let shareRange = focusedExpectation.shareRange, !shareRange.contains(metric.noteShare) {
                issues.append(.init(
                    code: "focused_lane_share_out_of_range",
                    message: "Lane \(focusedExpectation.lane.rawValue) expected share in \(formatRange(shareRange)) but got \(format(metric.noteShare))."
                ))
                penalty += proportionalPenalty(actual: metric.noteShare, expectedRange: shareRange, cap: 0.18)
            }

            if let notesPerMeasureRange = focusedExpectation.notesPerMeasureRange,
               !notesPerMeasureRange.contains(metric.notesPerMeasure) {
                issues.append(.init(
                    code: "focused_lane_density_out_of_range",
                    message: "Lane \(focusedExpectation.lane.rawValue) expected notes/measure in \(formatRange(notesPerMeasureRange)) but got \(format(metric.notesPerMeasure))."
                ))
                penalty += proportionalPenalty(actual: metric.notesPerMeasure, expectedRange: notesPerMeasureRange, cap: 0.18)
            }

            if let minNoteCount = focusedExpectation.minNoteCount,
               metric.noteCount < minNoteCount {
                issues.append(.init(
                    code: "focused_lane_note_count_too_low",
                    message: "Lane \(focusedExpectation.lane.rawValue) expected at least \(minNoteCount) notes but got \(metric.noteCount)."
                ))
                penalty += min(0.15, 0.04 * Double(minNoteCount - metric.noteCount))
            }

            if let maxNoteCount = focusedExpectation.maxNoteCount,
               metric.noteCount > maxNoteCount {
                issues.append(.init(
                    code: "focused_lane_note_count_too_high",
                    message: "Lane \(focusedExpectation.lane.rawValue) expected at most \(maxNoteCount) notes but got \(metric.noteCount)."
                ))
                penalty += min(0.15, 0.04 * Double(metric.noteCount - maxNoteCount))
            }
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
            issues: issues,
            regressionSnapshot: makeRegressionSnapshot(from: chart, metrics: metrics)
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
        let maxMeasureBurstiness = averageNotesPerMeasure > 0 ? Double(maxNotesPerMeasure) / averageNotesPerMeasure : 0
        let maxConsecutiveSameLaneNotes = longestSameLaneRun(in: chart.chart.notes)

        let laneUsage = Dictionary(grouping: chart.chart.notes, by: \.lane)
            .map { LaneUsageMetric(lane: $0.key, noteCount: $0.value.count) }
            .sorted { $0.lane.rawValue < $1.lane.rawValue }

        let laneBalance = laneUsage.map { metric in
            LaneBalanceMetric(
                lane: metric.lane,
                noteCount: metric.noteCount,
                noteShare: noteCount > 0 ? Double(metric.noteCount) / Double(noteCount) : 0,
                notesPerMeasure: measureCount > 0 ? Double(metric.noteCount) / Double(measureCount) : 0
            )
        }
        let focusedLaneLookup = Dictionary(uniqueKeysWithValues: laneBalance.map { ($0.lane, $0) })
        let focusedLaneBalance = focusedLanes.map { lane in
            focusedLaneLookup[lane] ?? LaneBalanceMetric(
                lane: lane,
                noteCount: 0,
                noteShare: 0,
                notesPerMeasure: 0
            )
        }

        let measureDensity = chart.chart.measures
            .sorted { $0.barIndex < $1.barIndex }
            .map { measure in
                MeasureDensityMetric(
                    measureIndex: measure.barIndex,
                    noteCount: notesPerMeasure[measure.barIndex]?.count ?? 0
                )
            }

        return ChartQualityMetrics(
            noteCount: noteCount,
            measureCount: measureCount,
            uniqueLanes: uniqueLanes,
            laneUsage: laneUsage,
            laneBalance: laneBalance,
            focusedLaneBalance: focusedLaneBalance,
            measureDensity: measureDensity,
            maxSimultaneousNotes: maxSimultaneousNotes,
            maxNotesPerBeat: maxNotesPerBeat,
            maxNotesPerMeasure: maxNotesPerMeasure,
            maxConsecutiveSameLaneNotes: maxConsecutiveSameLaneNotes,
            maxMeasureBurstiness: maxMeasureBurstiness,
            emptyMeasureCount: emptyMeasureCount,
            averageNotesPerMeasure: averageNotesPerMeasure
        )
    }

    private static func makeRegressionSnapshot(from chart: BaseChartContract, metrics: ChartQualityMetrics) -> ChartRegressionSnapshot {
        let preview = chart.chart.notes
            .sorted {
                if $0.tick == $1.tick { return $0.lane.rawValue < $1.lane.rawValue }
                return $0.tick < $1.tick
            }
            .prefix(12)
            .map { note in
                let velocity = note.velocity.map { String(format: "%.2f", $0) } ?? "nil"
                let subdivision = note.subdivisionIndex.map(String.init) ?? "nil"
                return "tick=\(note.tick):beat=\(note.beatIndex):sub=\(subdivision):lane=\(note.lane.rawValue):vel=\(velocity)"
            }

        return ChartRegressionSnapshot(
            measureCount: metrics.measureCount,
            noteCount: metrics.noteCount,
            lanes: metrics.uniqueLanes.map(\.rawValue),
            laneUsage: metrics.laneUsage.map { ChartRegressionLaneUsage(lane: $0.lane.rawValue, noteCount: $0.noteCount) },
            focusedLaneBalance: metrics.focusedLaneBalance.map {
                ChartRegressionLaneBalance(lane: $0.lane.rawValue, noteCount: $0.noteCount, noteShare: $0.noteShare)
            },
            measureDensity: metrics.measureDensity.map { ChartRegressionMeasureDensity(measureIndex: $0.measureIndex, noteCount: $0.noteCount) },
            notePreview: Array(preview)
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

    private static func longestSameLaneRun(in notes: [BaseChartNote]) -> Int {
        let orderedNotes = notes.sorted {
            if $0.tick == $1.tick {
                return $0.lane.rawValue < $1.lane.rawValue
            }
            return $0.tick < $1.tick
        }

        var best = 0
        var currentLane: DrumLane?
        var currentRun = 0

        for note in orderedNotes {
            if note.lane == currentLane {
                currentRun += 1
            } else {
                currentLane = note.lane
                currentRun = 1
            }
            best = max(best, currentRun)
        }

        return best
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

    private static func proportionalPenalty(actual: Double, expectedRange: DoubleRange, cap: Double) -> Double {
        if expectedRange.contains(actual) {
            return 0
        }

        let delta: Double
        let scale: Double
        if actual < expectedRange.min {
            delta = expectedRange.min - actual
            scale = max(expectedRange.min, 0.001)
        } else {
            delta = actual - expectedRange.max
            scale = max(expectedRange.max, 0.001)
        }

        return min(cap, (delta / scale) * cap)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatRange(_ range: DoubleRange) -> String {
        "\(format(range.min))...\(format(range.max))"
    }
}
