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
        let runtime = firstDictionary(in: payload, keys: ["runtime"]) ?? [:]
        let timingProvenance = extractTimingProvenance(from: payload)
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
                analyzerCommand: commandTemplate,
                timingProvenance: timingProvenance,
                runtimeBackend: string(firstValue(in: runtime, keys: ["backend", "wrapper", "primaryBackend"])),
                runtimeBackendCommand: string(firstValue(in: runtime, keys: ["backendCommand", "timingBackendCommand"])),
                runtimeSelectedBackend: string(firstValue(in: runtime, keys: ["selectedBackend"])),
                runtimeFallbackUsed: bool(firstValue(in: runtime, keys: ["fallbackUsed"])),
                runtimeFallbackReason: string(firstValue(in: runtime, keys: ["fallbackReason", "eventBackendFailure"])),
                runtimeFallbackErrorSummary: timingProvenance?.fallbackSummary
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
    public let timingProvenance: AudioAnalysisTimingProvenance?
    public let runtimeBackend: String?
    public let runtimeBackendCommand: String?
    public let runtimeSelectedBackend: String?
    public let runtimeFallbackUsed: Bool?
    public let runtimeFallbackReason: String?
    public let runtimeFallbackErrorSummary: AudioAnalysisFallbackSummary?

    public init(
        analyzedAt: Date,
        durationSeconds: Double?,
        audioTrackCount: Int,
        estimatedSegmentCount: Int,
        estimatedTempoBPM: Double? = nil,
        downbeatOffsetSeconds: Double? = nil,
        confidence: Double? = nil,
        artifactURI: String? = nil,
        analyzerCommand: String? = nil,
        timingProvenance: AudioAnalysisTimingProvenance? = nil,
        runtimeBackend: String? = nil,
        runtimeBackendCommand: String? = nil,
        runtimeSelectedBackend: String? = nil,
        runtimeFallbackUsed: Bool? = nil,
        runtimeFallbackReason: String? = nil,
        runtimeFallbackErrorSummary: AudioAnalysisFallbackSummary? = nil
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
        self.timingProvenance = timingProvenance
        self.runtimeBackend = runtimeBackend
        self.runtimeBackendCommand = runtimeBackendCommand
        self.runtimeSelectedBackend = runtimeSelectedBackend
        self.runtimeFallbackUsed = runtimeFallbackUsed
        self.runtimeFallbackReason = runtimeFallbackReason
        self.runtimeFallbackErrorSummary = runtimeFallbackErrorSummary
    }
}

extension AudioAnalysisSummary: JSONStringEncodable {}

public struct AudioAnalysisTimingProvenance: Codable, Sendable {
    public let backend: String
    public let timingSource: String
    public let backendCommand: String?
    public let selectedBackend: String?
    public let fallbackUsed: Bool
    public let fallbackSummary: AudioAnalysisFallbackSummary?

    public init(
        backend: String,
        timingSource: String,
        backendCommand: String? = nil,
        selectedBackend: String? = nil,
        fallbackUsed: Bool,
        fallbackSummary: AudioAnalysisFallbackSummary? = nil
    ) {
        self.backend = backend
        self.timingSource = timingSource
        self.backendCommand = backendCommand
        self.selectedBackend = selectedBackend
        self.fallbackUsed = fallbackUsed
        self.fallbackSummary = fallbackSummary
    }
}

public struct AudioAnalysisFallbackSummary: Codable, Sendable {
    public let reason: String
    public let category: String
    public let errorSummary: String?

    public init(reason: String, category: String, errorSummary: String? = nil) {
        self.reason = reason
        self.category = category
        self.errorSummary = errorSummary
    }
}

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

private func extractTimingProvenance(from payload: [String: Any]) -> AudioAnalysisTimingProvenance? {
    let runtime = firstDictionary(in: payload, keys: ["runtime"]) ?? [:]
    let selectedBackend = string(firstValue(in: runtime, keys: ["selectedBackend"]))
    let fallbackUsed = bool(firstValue(in: runtime, keys: ["fallbackUsed"])) ?? false
    let fallbackReason = string(firstValue(in: runtime, keys: ["fallbackReason"]))

    if let backend = string(firstValue(in: runtime, keys: ["backend"])), backend.contains("beat-this-backend.py") {
        return AudioAnalysisTimingProvenance(
            backend: "beat_this",
            timingSource: fallbackUsed ? "fallback" : "primary",
            backendCommand: string(firstValue(in: runtime, keys: ["backendCommand"])),
            selectedBackend: selectedBackend,
            fallbackUsed: fallbackUsed,
            fallbackSummary: fallbackReason.map(makeFallbackSummary(reason:))
        )
    }

    if string(firstValue(in: runtime, keys: ["primaryBackend"]))?.contains("beat-this-backend.py") == true {
        let fallbackCommand = string(firstValue(in: runtime, keys: ["fallbackBackendCommand"]))
        return AudioAnalysisTimingProvenance(
            backend: backendLabel(from: fallbackCommand) ?? "fallback_backend",
            timingSource: "fallback",
            backendCommand: fallbackCommand,
            selectedBackend: selectedBackend ?? "fallback",
            fallbackUsed: true,
            fallbackSummary: fallbackReason.map(makeFallbackSummary(reason:))
        )
    }

    if let selectedBackend, let backendCommand = string(firstValue(in: runtime, keys: ["backendCommand", "timingBackendCommand"])) {
        let label = backendCommand.contains("beat-this-backend.py") ? "beat_this" : (backendLabel(from: backendCommand) ?? selectedBackend)
        return AudioAnalysisTimingProvenance(
            backend: label,
            timingSource: selectedBackend == "fallback" ? "fallback" : "primary",
            backendCommand: backendCommand,
            selectedBackend: selectedBackend,
            fallbackUsed: fallbackUsed || selectedBackend == "fallback",
            fallbackSummary: fallbackReason.map(makeFallbackSummary(reason:))
        )
    }

    if let warning = extractWarnings(from: payload).first(where: { $0.contains("beat_this unavailable/failed; used fallback backend:") }) {
        let reason = warning.replacingOccurrences(of: "beat_this unavailable/failed; used fallback backend:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AudioAnalysisTimingProvenance(
            backend: "fallback_backend",
            timingSource: "fallback",
            backendCommand: string(firstValue(in: runtime, keys: ["fallbackBackendCommand"])),
            selectedBackend: selectedBackend ?? "fallback",
            fallbackUsed: true,
            fallbackSummary: makeFallbackSummary(reason: reason)
        )
    }

    return nil
}

private func makeFallbackSummary(reason: String) -> AudioAnalysisFallbackSummary {
    let category: String
    if reason.contains("payload did not contain recognizable") {
        category = "validation"
    } else if reason.contains("not configured") {
        category = "configuration"
    } else if reason.contains("policy") {
        category = "policy"
    } else {
        category = "execution"
    }
    return AudioAnalysisFallbackSummary(reason: reason, category: category, errorSummary: summarizeFallbackError(reason))
}

private func summarizeFallbackError(_ reason: String) -> String? {
    if let range = reason.range(of: ": ", options: .backwards) {
        let suffix = String(reason[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }
    return nil
}

private func backendLabel(from command: String?) -> String? {
    guard let command else { return nil }
    if command.contains("beat-this-backend.py") {
        return "beat_this"
    }
    if command.contains("backend-analyzer.py") {
        return "heuristic_backend"
    }
    if command.contains("madmom-fallback-backend.py") {
        return "madmom_fallback"
    }
    return nil
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

private func bool(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    case let value as String:
        switch value.lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
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
