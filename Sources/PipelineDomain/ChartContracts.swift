import Foundation

public struct NormalizedAnalysisContract: Codable, Sendable {
    public static let schemaVersion = "1.0.0"
    public static let schemaURI = "https://masterofdrums.dev/schemas/normalized-analysis-result.schema.json"

    public let schemaVersion: String
    public let schemaURI: String
    public let analysisStage: String
    public let status: String
    public let source: NormalizedAnalysisSource
    public let summary: NormalizedAnalysisSummary
    public let beatGrid: [BeatGridEvent]
    public let drumEvents: [DetectedDrumEvent]
    public let warnings: [String]
    public let note: String?

    public init(
        schemaVersion: String = Self.schemaVersion,
        schemaURI: String = Self.schemaURI,
        analysisStage: String = "chart_generation_ready_v1",
        status: String = "completed",
        source: NormalizedAnalysisSource,
        summary: NormalizedAnalysisSummary,
        beatGrid: [BeatGridEvent],
        drumEvents: [DetectedDrumEvent],
        warnings: [String] = [],
        note: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.schemaURI = schemaURI
        self.analysisStage = analysisStage
        self.status = status
        self.source = source
        self.summary = summary
        self.beatGrid = beatGrid
        self.drumEvents = drumEvents
        self.warnings = warnings
        self.note = note
    }
}

extension NormalizedAnalysisContract: JSONStringEncodable {}

public struct NormalizedAnalysisSource: Codable, Sendable {
    public let sourceType: String
    public let sourceURI: String
    public let requestedBy: String
    public let audioAnalysisArtifactURI: String

    public init(sourceType: String, sourceURI: String, requestedBy: String, audioAnalysisArtifactURI: String) {
        self.sourceType = sourceType
        self.sourceURI = sourceURI
        self.requestedBy = requestedBy
        self.audioAnalysisArtifactURI = audioAnalysisArtifactURI
    }
}

public struct NormalizedAnalysisSummary: Codable, Sendable {
    public let normalizedAt: Date
    public let durationSeconds: Double?
    public let estimatedTempoBPM: Double?
    public let downbeatOffsetSeconds: Double?
    public let beatCount: Int
    public let barCount: Int
    public let drumEventCount: Int
    public let predominantTimeSignature: TimeSignature
    public let confidence: Double?

    public init(
        normalizedAt: Date,
        durationSeconds: Double?,
        estimatedTempoBPM: Double?,
        downbeatOffsetSeconds: Double?,
        beatCount: Int,
        barCount: Int,
        drumEventCount: Int,
        predominantTimeSignature: TimeSignature,
        confidence: Double? = nil
    ) {
        self.normalizedAt = normalizedAt
        self.durationSeconds = durationSeconds
        self.estimatedTempoBPM = estimatedTempoBPM
        self.downbeatOffsetSeconds = downbeatOffsetSeconds
        self.beatCount = beatCount
        self.barCount = barCount
        self.drumEventCount = drumEventCount
        self.predominantTimeSignature = predominantTimeSignature
        self.confidence = confidence
    }
}

extension NormalizedAnalysisSummary: JSONStringEncodable {}

public struct TimeSignature: Codable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

public struct BeatGridEvent: Codable, Sendable {
    public let beatIndex: Int
    public let barIndex: Int
    public let beatInBar: Int
    public let subdivisionIndex: Int
    public let subdivisionInBeat: Int
    public let startSeconds: Double
    public let durationSeconds: Double?
    public let isDownbeat: Bool
    public let tempoBPM: Double?
    public let timeSignature: TimeSignature?
    public let confidence: Double?

    public init(
        beatIndex: Int,
        barIndex: Int,
        beatInBar: Int,
        subdivisionIndex: Int,
        subdivisionInBeat: Int,
        startSeconds: Double,
        durationSeconds: Double? = nil,
        isDownbeat: Bool,
        tempoBPM: Double? = nil,
        timeSignature: TimeSignature? = nil,
        confidence: Double? = nil
    ) {
        self.beatIndex = beatIndex
        self.barIndex = barIndex
        self.beatInBar = beatInBar
        self.subdivisionIndex = subdivisionIndex
        self.subdivisionInBeat = subdivisionInBeat
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.isDownbeat = isDownbeat
        self.tempoBPM = tempoBPM
        self.timeSignature = timeSignature
        self.confidence = confidence
    }
}

public struct DetectedDrumEvent: Codable, Sendable {
    public let eventID: String
    public let onsetSeconds: Double
    public let onsetBeatIndex: Int?
    public let onsetSubdivisionIndex: Int?
    public let lane: DrumLane
    public let velocity: Double?
    public let sourceLabel: String?
    public let confidence: Double?

    public init(
        eventID: String = UUID().uuidString,
        onsetSeconds: Double,
        onsetBeatIndex: Int? = nil,
        onsetSubdivisionIndex: Int? = nil,
        lane: DrumLane,
        velocity: Double? = nil,
        sourceLabel: String? = nil,
        confidence: Double? = nil
    ) {
        self.eventID = eventID
        self.onsetSeconds = onsetSeconds
        self.onsetBeatIndex = onsetBeatIndex
        self.onsetSubdivisionIndex = onsetSubdivisionIndex
        self.lane = lane
        self.velocity = velocity
        self.sourceLabel = sourceLabel
        self.confidence = confidence
    }
}

public enum DrumLane: String, Codable, Sendable, CaseIterable {
    case kick
    case snare
    case hihatClosed = "hihat_closed"
    case hihatOpen = "hihat_open"
    case tomLow = "tom_low"
    case tomMid = "tom_mid"
    case tomHigh = "tom_high"
    case crash
    case ride
    case clap
    case percussion
}

public struct BaseChartContract: Codable, Sendable {
    public static let schemaVersion = "1.0.0"
    public static let schemaURI = "https://masterofdrums.dev/schemas/base-chart.schema.json"

    public let schemaVersion: String
    public let schemaURI: String
    public let chartStage: String
    public let status: String
    public let source: BaseChartSource
    public let chart: BaseChartData
    public let warnings: [String]
    public let note: String?

    public init(
        schemaVersion: String = Self.schemaVersion,
        schemaURI: String = Self.schemaURI,
        chartStage: String = "base_chart_v1",
        status: String = "completed",
        source: BaseChartSource,
        chart: BaseChartData,
        warnings: [String] = [],
        note: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.schemaURI = schemaURI
        self.chartStage = chartStage
        self.status = status
        self.source = source
        self.chart = chart
        self.warnings = warnings
        self.note = note
    }
}

extension BaseChartContract: JSONStringEncodable {}

public struct BaseChartSource: Codable, Sendable {
    public let normalizedAnalysisArtifactURI: String
    public let sourceType: String
    public let sourceURI: String
    public let requestedBy: String

    public init(normalizedAnalysisArtifactURI: String, sourceType: String, sourceURI: String, requestedBy: String) {
        self.normalizedAnalysisArtifactURI = normalizedAnalysisArtifactURI
        self.sourceType = sourceType
        self.sourceURI = sourceURI
        self.requestedBy = requestedBy
    }
}

public struct BaseChartData: Codable, Sendable {
    public let generatedAt: Date
    public let ticksPerBeat: Int
    public let offsetSeconds: Double
    public let lanes: [DrumLane]
    public let difficulty: String
    public let measures: [BaseChartMeasure]
    public let notes: [BaseChartNote]

    public init(
        generatedAt: Date,
        ticksPerBeat: Int = 480,
        offsetSeconds: Double = 0,
        lanes: [DrumLane],
        difficulty: String,
        measures: [BaseChartMeasure],
        notes: [BaseChartNote]
    ) {
        self.generatedAt = generatedAt
        self.ticksPerBeat = ticksPerBeat
        self.offsetSeconds = offsetSeconds
        self.lanes = lanes
        self.difficulty = difficulty
        self.measures = measures
        self.notes = notes
    }
}

public struct BaseChartMeasure: Codable, Sendable {
    public let barIndex: Int
    public let startBeatIndex: Int
    public let beatCount: Int
    public let timeSignature: TimeSignature

    public init(barIndex: Int, startBeatIndex: Int, beatCount: Int, timeSignature: TimeSignature) {
        self.barIndex = barIndex
        self.startBeatIndex = startBeatIndex
        self.beatCount = beatCount
        self.timeSignature = timeSignature
    }
}

public struct BaseChartNote: Codable, Sendable {
    public let noteID: String
    public let lane: DrumLane
    public let tick: Int
    public let beatIndex: Int
    public let subdivisionIndex: Int?
    public let startSeconds: Double
    public let durationTicks: Int
    public let velocity: Double?
    public let sourceEventID: String?

    public init(
        noteID: String = UUID().uuidString,
        lane: DrumLane,
        tick: Int,
        beatIndex: Int,
        subdivisionIndex: Int? = nil,
        startSeconds: Double,
        durationTicks: Int = 0,
        velocity: Double? = nil,
        sourceEventID: String? = nil
    ) {
        self.noteID = noteID
        self.lane = lane
        self.tick = tick
        self.beatIndex = beatIndex
        self.subdivisionIndex = subdivisionIndex
        self.startSeconds = startSeconds
        self.durationTicks = durationTicks
        self.velocity = velocity
        self.sourceEventID = sourceEventID
    }
}
