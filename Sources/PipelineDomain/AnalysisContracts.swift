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
        let root = dict ?? [:]
        let payload = unwrapPayload(dict)
        let analysisDict = firstDictionary(in: payload, keys: ["analysis"]) ?? [:]
        let segmentsSource = firstArray(in: payload, keys: ["segments", "sections"]) ?? []
        let segments = segmentsSource.enumerated().compactMap { index, item -> AudioAnalysisSegment? in
            guard let item else { return nil }
            return AudioAnalysisSegment(
                index: int(item["index"] ?? item["segmentIndex"] ?? item["segment_index"]) ?? index,
                startSeconds: double(item["startSeconds"] ?? item["start_seconds"] ?? item["start"] ?? item["beginSeconds"] ?? item["begin_seconds"]),
                endSeconds: double(item["endSeconds"] ?? item["end_seconds"] ?? item["end"] ?? item["stopSeconds"] ?? item["stop_seconds"]),
                label: string(item["label"] ?? item["name"] ?? item["type"]),
                confidence: double(item["confidence"] ?? item["score"])
            )
        }
        let duration = double(firstValue(in: analysisDict, keys: ["durationSeconds", "duration_seconds", "duration"]) ?? firstValue(in: payload, keys: ["durationSeconds", "duration_seconds", "duration"]))
        let segmentCount = int(firstValue(in: analysisDict, keys: ["estimatedSegmentCount", "estimated_segment_count", "segmentCount", "segment_count"]))
            ?? int(firstValue(in: payload, keys: ["estimatedSegmentCount", "estimated_segment_count", "segmentCount", "segment_count"]))
            ?? segments.count
        let trackCount = int(firstValue(in: analysisDict, keys: ["audioTrackCount", "audio_track_count", "trackCount", "track_count"]))
            ?? int(firstValue(in: payload, keys: ["audioTrackCount", "audio_track_count", "trackCount", "track_count"]))
            ?? 0
        let warnings = uniqueStrings(extractWarnings(from: root) + extractWarnings(from: payload))
        let note = extractNote(from: payload) ?? extractNote(from: root)

        return AudioAnalysisContract(
            source: AudioAnalysisSource(sourceType: sourceType, sourceURI: sourceURI, requestedBy: requestedBy),
            analysis: AudioAnalysisSummary(
                analyzedAt: analyzedAt,
                durationSeconds: duration,
                audioTrackCount: trackCount,
                estimatedSegmentCount: segmentCount,
                estimatedTempoBPM: double(firstValue(in: analysisDict, keys: ["estimatedTempoBPM", "estimated_tempo_bpm", "tempoBPM", "tempo_bpm"]) ?? firstValue(in: payload, keys: ["estimatedTempoBPM", "estimated_tempo_bpm", "tempoBPM", "tempo_bpm"])),
                downbeatOffsetSeconds: double(firstValue(in: analysisDict, keys: ["downbeatOffsetSeconds", "downbeat_offset_seconds"]) ?? firstValue(in: payload, keys: ["downbeatOffsetSeconds", "downbeat_offset_seconds"])),
                confidence: double(firstValue(in: analysisDict, keys: ["confidence", "score"]) ?? firstValue(in: payload, keys: ["confidence", "score"])),
                artifactURI: nil,
                analyzerCommand: commandTemplate
            ),
            segments: segments,
            warnings: warnings,
            note: note,
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

private func unwrapPayload(_ dict: [String: Any]?) -> [String: Any] {
    guard let dict else { return [:] }
    var current = dict
    let containerKeys = ["result", "output", "payload", "data"]
    while let nested = firstDictionary(in: current, keys: containerKeys) {
        current = nested
    }
    return current
}

private func firstDictionary(in dict: [String: Any], keys: [String]) -> [String: Any]? {
    for key in keys {
        if let value = dict[key] as? [String: Any] {
            return value
        }
    }
    return nil
}

private func firstArray(in dict: [String: Any], keys: [String]) -> [[String: Any]?]? {
    for key in keys {
        if let values = dict[key] as? [[String: Any]] {
            return values.map(Optional.some)
        }
        if let values = dict[key] as? [Any] {
            return values.map { $0 as? [String: Any] }
        }
    }
    return nil
}

private func firstValue(in dict: [String: Any], keys: [String]) -> Any? {
    for key in keys {
        if let value = dict[key] {
            return value
        }
    }
    return nil
}

private func extractWarnings(from payload: [String: Any]) -> [String] {
    let sources = [
        firstValue(in: payload, keys: ["warnings", "warningMessages", "warning_messages"]),
        firstValue(in: firstDictionary(in: payload, keys: ["analysis"]) ?? [:], keys: ["warnings", "warningMessages", "warning_messages"]),
        firstValue(in: firstDictionary(in: payload, keys: ["runtime"]) ?? [:], keys: ["warnings"])
    ]
    var warnings: [String] = []
    for source in sources {
        switch source {
        case let values as [String]:
            warnings.append(contentsOf: values)
        case let values as [Any]:
            warnings.append(contentsOf: values.compactMap(string))
        case let value?:
            if let warning = string(value) {
                warnings.append(warning)
            }
        default:
            break
        }
    }
    return warnings
}

private func extractNote(from payload: [String: Any]) -> String? {
    if let note = string(firstValue(in: payload, keys: ["note", "message", "summary"])) {
        return note
    }
    if let analysis = firstDictionary(in: payload, keys: ["analysis"]), let note = string(firstValue(in: analysis, keys: ["note", "message", "summary"])) {
        return note
    }
    return nil
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for value in values where seen.insert(value).inserted {
        ordered.append(value)
    }
    return ordered
}

private func double(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        return value
    case let value as Float:
        return Double(value)
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

private func int(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
        return value
    case let value as NSNumber:
        return value.intValue
    case let value as String:
        return Int(value)
    default:
        return nil
    }
}

private func string(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        return value
    case let value as NSString:
        return value as String
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
