import Foundation

public protocol JSONStringEncodable: Encodable {
    func toJSONString() -> String
}

public extension JSONStringEncodable {
    func toJSONString() -> String {
        let encoder = JSONEncoder.pipeline
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct AudioAnalysisContract: Codable, Sendable {
    public static let schemaVersion = "1.0.0"
    public static let schemaURI = "https://masterofdrums.dev/schemas/audio-analysis-result.schema.json"

    public let schemaVersion: String
    public let schemaURI: String
    public let analysisStage: String
    public let status: String
    public let source: AudioAnalysisSource
    public let analysis: AudioAnalysisSummary
    public let segments: [AudioAnalysisSegment]
    public let warnings: [String]
    public let note: String?
    public let rawAnalyzerOutput: RawJSONValue?

    public init(
        schemaVersion: String = Self.schemaVersion,
        schemaURI: String = Self.schemaURI,
        analysisStage: String = "audio_analysis_mvp",
        status: String = "completed",
        source: AudioAnalysisSource,
        analysis: AudioAnalysisSummary,
        segments: [AudioAnalysisSegment],
        warnings: [String] = [],
        note: String? = nil,
        rawAnalyzerOutput: RawJSONValue? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.schemaURI = schemaURI
        self.analysisStage = analysisStage
        self.status = status
        self.source = source
        self.analysis = analysis
        self.segments = segments
        self.warnings = warnings
        self.note = note
        self.rawAnalyzerOutput = rawAnalyzerOutput
    }

    public func write(to url: URL) throws {
        try toJSONString().write(to: url, atomically: true, encoding: .utf8)
    }

    public static func fromAnalyzerOutput(
        _ object: Any,
        sourceType: String,
        sourceURI: String,
        requestedBy: String,
        analyzedAt: Date,
        commandTemplate: String
    ) -> AudioAnalysisContract {
        let raw = RawJSONValue.from(object)
        let dict = object as? [String: Any]
        let analysisDict = dict?["analysis"] as? [String: Any]
        let segments = (dict?["segments"] as? [[String: Any]])?.enumerated().map { index, item in
            AudioAnalysisSegment(
                index: (item["index"] as? Int) ?? index,
                startSeconds: double(item["startSeconds"] ?? item["start_seconds"]),
                endSeconds: double(item["endSeconds"] ?? item["end_seconds"]),
                label: item["label"] as? String,
                confidence: double(item["confidence"])
            )
        } ?? []
        let duration = double(analysisDict?["durationSeconds"] ?? analysisDict?["duration_seconds"] ?? dict?["durationSeconds"] ?? dict?["duration_seconds"])
        let segmentCount = (analysisDict?["estimatedSegmentCount"] as? Int) ?? (analysisDict?["estimated_segment_count"] as? Int) ?? segments.count
        let trackCount = (analysisDict?["audioTrackCount"] as? Int) ?? (analysisDict?["audio_track_count"] as? Int) ?? 0

        return AudioAnalysisContract(
            source: AudioAnalysisSource(sourceType: sourceType, sourceURI: sourceURI, requestedBy: requestedBy),
            analysis: AudioAnalysisSummary(
                analyzedAt: analyzedAt,
                durationSeconds: duration,
                audioTrackCount: trackCount,
                estimatedSegmentCount: segmentCount,
                estimatedTempoBPM: double(analysisDict?["estimatedTempoBPM"] ?? analysisDict?["estimated_tempo_bpm"] ?? dict?["estimatedTempoBPM"] ?? dict?["estimated_tempo_bpm"]),
                downbeatOffsetSeconds: double(analysisDict?["downbeatOffsetSeconds"] ?? analysisDict?["downbeat_offset_seconds"] ?? dict?["downbeatOffsetSeconds"] ?? dict?["downbeat_offset_seconds"]),
                confidence: double(analysisDict?["confidence"] ?? dict?["confidence"]),
                artifactURI: nil,
                analyzerCommand: commandTemplate
            ),
            segments: segments,
            warnings: dict?["warnings"] as? [String] ?? [],
            note: dict?["note"] as? String,
            rawAnalyzerOutput: raw
        )
    }
}

extension AudioAnalysisContract: JSONStringEncodable {}

public struct AudioAnalysisSource: Codable, Sendable {
    public let sourceType: String
    public let sourceURI: String
    public let requestedBy: String

    public init(sourceType: String, sourceURI: String, requestedBy: String) {
        self.sourceType = sourceType
        self.sourceURI = sourceURI
        self.requestedBy = requestedBy
    }
}

public struct AudioAnalysisSummary: Codable, Sendable {
    public let analyzedAt: Date
    public let durationSeconds: Double?
    public let audioTrackCount: Int
    public let estimatedSegmentCount: Int
    public let estimatedTempoBPM: Double?
    public let downbeatOffsetSeconds: Double?
    public let confidence: Double?
    public let artifactURI: String?
    public let analyzerCommand: String?

    public init(
        analyzedAt: Date,
        durationSeconds: Double?,
        audioTrackCount: Int,
        estimatedSegmentCount: Int,
        estimatedTempoBPM: Double? = nil,
        downbeatOffsetSeconds: Double? = nil,
        confidence: Double? = nil,
        artifactURI: String? = nil,
        analyzerCommand: String? = nil
    ) {
        self.analyzedAt = analyzedAt
        self.durationSeconds = durationSeconds
        self.audioTrackCount = audioTrackCount
        self.estimatedSegmentCount = estimatedSegmentCount
        self.estimatedTempoBPM = estimatedTempoBPM
        self.downbeatOffsetSeconds = downbeatOffsetSeconds
        self.confidence = confidence
        self.artifactURI = artifactURI
        self.analyzerCommand = analyzerCommand
    }
}

extension AudioAnalysisSummary: JSONStringEncodable {}

public struct AudioAnalysisSegment: Codable, Sendable {
    public let index: Int
    public let startSeconds: Double?
    public let endSeconds: Double?
    public let label: String?
    public let confidence: Double?

    public init(index: Int, startSeconds: Double?, endSeconds: Double?, label: String?, confidence: Double? = nil) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.label = label
        self.confidence = confidence
    }
}

public enum RawJSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RawJSONValue])
    case array([RawJSONValue])
    case null

    public static func from(_ value: Any) -> RawJSONValue {
        switch value {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [String: Any]:
            return .object(value.mapValues(Self.from))
        case let value as [Any]:
            return .array(value.map(Self.from))
        default:
            return .null
        }
    }

    public var dictionary: [String: RawJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var array: [RawJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

private func double(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        return value
    case let value as Int:
        return Double(value)
    case let value as NSNumber:
        return value.doubleValue
    case let value as String:
        return Double(value)
    default:
        return nil
    }
}

public extension JSONEncoder {
    static var pipeline: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
