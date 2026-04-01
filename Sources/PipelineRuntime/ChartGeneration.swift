import Foundation
import PipelineDomain

struct ChartGenerationOutput {
    let normalized: NormalizedAnalysisContract
    let baseChart: BaseChartContract
}

enum ChartGenerator {
    static func generate(from analysis: AudioAnalysisContract, generatedAt: Date, normalizedAnalysisArtifactURI: String) -> ChartGenerationOutput {
        let timeSignature = TimeSignature(numerator: 4, denominator: 4)
        let ticksPerBeat = 480
        let beatGrid = makeBeatGrid(from: analysis, timeSignature: timeSignature)
        let drumEvents = makeDrumEvents(from: analysis, beatGrid: beatGrid)
        let measures = makeMeasures(from: beatGrid, timeSignature: timeSignature)
        let warnings = combinedWarnings(for: analysis, usedFallbackDrumEvents: drumEvents.allSatisfy { ($0.sourceLabel ?? "").hasPrefix("heuristic_") })

        let normalized = NormalizedAnalysisContract(
            source: NormalizedAnalysisSource(
                sourceType: analysis.source.sourceType,
                sourceURI: analysis.source.sourceURI,
                requestedBy: analysis.source.requestedBy,
                audioAnalysisArtifactURI: analysis.analysis.artifactURI ?? normalizedAnalysisArtifactURI
            ),
            summary: NormalizedAnalysisSummary(
                normalizedAt: generatedAt,
                durationSeconds: analysis.analysis.durationSeconds,
                estimatedTempoBPM: analysis.analysis.estimatedTempoBPM,
                downbeatOffsetSeconds: analysis.analysis.downbeatOffsetSeconds,
                beatCount: Set(beatGrid.map(\.beatIndex)).count,
                barCount: measures.count,
                drumEventCount: drumEvents.count,
                predominantTimeSignature: timeSignature,
                confidence: analysis.analysis.confidence
            ),
            beatGrid: beatGrid,
            drumEvents: drumEvents,
            warnings: warnings,
            note: drumEvents.contains(where: { !($0.sourceLabel ?? "").hasPrefix("heuristic_") })
                ? "Normalized analysis generated from analyzer timing/event output."
                : "Heuristic normalization generated from coarse analysis summary."
        )

        let notes = makeChartNotes(from: drumEvents, ticksPerBeat: ticksPerBeat)
        let lanes = Array(Set(notes.map(\.lane))).sorted { $0.rawValue < $1.rawValue }
        let baseChart = BaseChartContract(
            source: BaseChartSource(
                normalizedAnalysisArtifactURI: normalizedAnalysisArtifactURI,
                sourceType: analysis.source.sourceType,
                sourceURI: analysis.source.sourceURI,
                requestedBy: analysis.source.requestedBy
            ),
            chart: BaseChartData(
                generatedAt: generatedAt,
                ticksPerBeat: ticksPerBeat,
                offsetSeconds: analysis.analysis.downbeatOffsetSeconds ?? 0,
                lanes: lanes.isEmpty ? [.kick] : lanes,
                difficulty: drumEvents.contains(where: { !($0.sourceLabel ?? "").hasPrefix("heuristic_") }) ? "prototype" : "normal",
                measures: measures,
                notes: notes
            ),
            warnings: warnings,
            note: drumEvents.contains(where: { !($0.sourceLabel ?? "").hasPrefix("heuristic_") })
                ? "Base chart generated from analyzer timing and mapped drum-event candidates."
                : "Heuristic base chart intended as a deterministic playable scaffold."
        )

        return ChartGenerationOutput(normalized: normalized, baseChart: baseChart)
    }

    private static func combinedWarnings(for analysis: AudioAnalysisContract, usedFallbackDrumEvents: Bool) -> [String] {
        var warnings = analysis.warnings
        if analysis.analysis.estimatedTempoBPM == nil {
            warnings.append("No analyzer tempo found; fallback 120 BPM grid used for chart-generation staging.")
        }
        if analysis.analysis.durationSeconds == nil {
            warnings.append("No analyzer duration found; normalized beat grid may be truncated.")
        }
        if usedFallbackDrumEvents {
            warnings.append("Analyzer did not provide usable drum-event candidates; emitted heuristic playable groove instead.")
        }
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }

    private static func makeBeatGrid(from analysis: AudioAnalysisContract, timeSignature: TimeSignature) -> [BeatGridEvent] {
        if let beatStarts = extractBeatStarts(from: analysis.rawAnalyzerOutput), !beatStarts.isEmpty {
            return beatGridFromBeatStarts(beatStarts.sorted(), tempoBPM: analysis.analysis.estimatedTempoBPM, confidence: analysis.analysis.confidence, timeSignature: timeSignature)
        }

        let tempo = analysis.analysis.estimatedTempoBPM ?? 120
        let secondsPerBeat = 60.0 / max(tempo, 1)
        let downbeatOffset = max(analysis.analysis.downbeatOffsetSeconds ?? 0, 0)
        let duration = max(analysis.analysis.durationSeconds ?? downbeatOffset + secondsPerBeat * 4, downbeatOffset + secondsPerBeat)
        let rawBeatCount = Int(ceil((duration - downbeatOffset) / secondsPerBeat))
        let beatCount = max(rawBeatCount, 1)
        let subdivisionsPerBeat = 2

        var beatGrid: [BeatGridEvent] = []
        beatGrid.reserveCapacity(beatCount * subdivisionsPerBeat)

        for beatIndex in 0..<beatCount {
            let barIndex = beatIndex / timeSignature.numerator
            let beatInBar = (beatIndex % timeSignature.numerator) + 1
            for subdivisionInBeat in 0..<subdivisionsPerBeat {
                let subdivisionIndex = beatIndex * subdivisionsPerBeat + subdivisionInBeat
                let startSeconds = downbeatOffset + (Double(beatIndex) + Double(subdivisionInBeat) / Double(subdivisionsPerBeat)) * secondsPerBeat
                guard startSeconds <= duration + 0.0001 else { continue }
                let slotDuration = secondsPerBeat / Double(subdivisionsPerBeat)
                let durationSeconds = min(slotDuration, max(duration - startSeconds, 0))
                beatGrid.append(
                    BeatGridEvent(
                        beatIndex: beatIndex,
                        barIndex: barIndex,
                        beatInBar: beatInBar,
                        subdivisionIndex: subdivisionIndex,
                        subdivisionInBeat: subdivisionInBeat,
                        startSeconds: startSeconds,
                        durationSeconds: durationSeconds,
                        isDownbeat: beatInBar == 1 && subdivisionInBeat == 0,
                        tempoBPM: tempo,
                        timeSignature: subdivisionInBeat == 0 ? timeSignature : nil,
                        confidence: analysis.analysis.confidence
                    )
                )
            }
        }

        return beatGrid
    }

    private static func beatGridFromBeatStarts(_ beatStarts: [Double], tempoBPM: Double?, confidence: Double?, timeSignature: TimeSignature) -> [BeatGridEvent] {
        beatStarts.enumerated().map { index, startSeconds in
            let durationSeconds: Double? = index + 1 < beatStarts.count ? max(0, beatStarts[index + 1] - startSeconds) : nil
            let barIndex = index / timeSignature.numerator
            let beatInBar = (index % timeSignature.numerator) + 1
            return BeatGridEvent(
                beatIndex: index,
                barIndex: barIndex,
                beatInBar: beatInBar,
                subdivisionIndex: index,
                subdivisionInBeat: 0,
                startSeconds: startSeconds,
                durationSeconds: durationSeconds,
                isDownbeat: beatInBar == 1,
                tempoBPM: tempoBPM,
                timeSignature: beatInBar == 1 ? timeSignature : nil,
                confidence: confidence
            )
        }
    }

    private static func makeDrumEvents(from analysis: AudioAnalysisContract, beatGrid: [BeatGridEvent]) -> [DetectedDrumEvent] {
        let candidates = extractRawDrumEventCandidates(from: analysis.rawAnalyzerOutput)
        let mapped = candidates.enumerated().compactMap { index, candidate -> DetectedDrumEvent? in
            guard let onsetSeconds = rawDouble(candidate["onsetSeconds"] ?? candidate["onset_seconds"] ?? candidate["time"] ?? candidate["timestamp"]),
                  let lane = mapLane(candidate["lane"] ?? candidate["label"] ?? candidate["sourceLabel"] ?? candidate["source_label"]) else {
                return nil
            }
            let anchor = nearestAnchor(to: onsetSeconds, beatGrid: beatGrid)
            return DetectedDrumEvent(
                eventID: rawString(candidate["eventID"] ?? candidate["event_id"]) ?? "evt-\(index)",
                onsetSeconds: onsetSeconds,
                onsetBeatIndex: anchor?.beatIndex,
                onsetSubdivisionIndex: anchor?.subdivisionIndex,
                lane: lane,
                velocity: rawDouble(candidate["velocity"]),
                sourceLabel: rawString(candidate["sourceLabel"] ?? candidate["source_label"] ?? candidate["label"]),
                confidence: rawDouble(candidate["confidence"])
            )
        }

        if !mapped.isEmpty {
            return mapped.sorted {
                if $0.onsetSeconds == $1.onsetSeconds { return $0.lane.rawValue < $1.lane.rawValue }
                return $0.onsetSeconds < $1.onsetSeconds
            }
        }

        return heuristicDrumEvents(from: beatGrid, confidence: analysis.analysis.confidence)
    }

    private static func heuristicDrumEvents(from beatGrid: [BeatGridEvent], confidence: Double?) -> [DetectedDrumEvent] {
        var events: [DetectedDrumEvent] = []
        for anchor in beatGrid {
            if anchor.subdivisionInBeat > 0 {
                events.append(
                    DetectedDrumEvent(
                        onsetSeconds: anchor.startSeconds,
                        onsetBeatIndex: anchor.beatIndex,
                        onsetSubdivisionIndex: anchor.subdivisionIndex,
                        lane: .hihatClosed,
                        velocity: 0.55,
                        sourceLabel: "heuristic_hat_subdivision",
                        confidence: confidence
                    )
                )
                continue
            }

            events.append(
                DetectedDrumEvent(
                    onsetSeconds: anchor.startSeconds,
                    onsetBeatIndex: anchor.beatIndex,
                    onsetSubdivisionIndex: anchor.subdivisionIndex,
                    lane: .hihatClosed,
                    velocity: anchor.isDownbeat ? 0.7 : 0.62,
                    sourceLabel: "heuristic_backbeat_hat",
                    confidence: confidence
                )
            )

            let mainLane: DrumLane
            let velocity: Double
            switch anchor.beatInBar {
            case 1:
                mainLane = .kick
                velocity = 0.9
            case 2, 4:
                mainLane = .snare
                velocity = 0.92
            case 3:
                mainLane = .kick
                velocity = 0.82
            default:
                mainLane = .hihatClosed
                velocity = 0.6
            }

            events.append(
                DetectedDrumEvent(
                    onsetSeconds: anchor.startSeconds,
                    onsetBeatIndex: anchor.beatIndex,
                    onsetSubdivisionIndex: anchor.subdivisionIndex,
                    lane: mainLane,
                    velocity: velocity,
                    sourceLabel: "heuristic_backbeat",
                    confidence: confidence
                )
            )
        }

        if let firstDownbeat = beatGrid.first(where: { $0.isDownbeat }) {
            events.append(
                DetectedDrumEvent(
                    onsetSeconds: firstDownbeat.startSeconds,
                    onsetBeatIndex: firstDownbeat.beatIndex,
                    onsetSubdivisionIndex: firstDownbeat.subdivisionIndex,
                    lane: .crash,
                    velocity: 0.95,
                    sourceLabel: "heuristic_phrase_start",
                    confidence: confidence
                )
            )
        }

        return events.sorted {
            if $0.onsetSeconds == $1.onsetSeconds { return $0.lane.rawValue < $1.lane.rawValue }
            return $0.onsetSeconds < $1.onsetSeconds
        }
    }

    private static func makeMeasures(from beatGrid: [BeatGridEvent], timeSignature: TimeSignature) -> [BaseChartMeasure] {
        let grouped = Dictionary(grouping: beatGrid.filter { $0.subdivisionInBeat == 0 }, by: \.barIndex)
        return grouped.keys.sorted().compactMap { barIndex in
            guard let first = grouped[barIndex]?.sorted(by: { $0.beatIndex < $1.beatIndex }).first else { return nil }
            return BaseChartMeasure(
                barIndex: barIndex,
                startBeatIndex: first.beatIndex,
                beatCount: timeSignature.numerator,
                timeSignature: timeSignature
            )
        }
    }

    private static func makeChartNotes(from drumEvents: [DetectedDrumEvent], ticksPerBeat: Int) -> [BaseChartNote] {
        let subdivisionTicks = ticksPerBeat / 2
        return drumEvents.map { event in
            let beatIndex = event.onsetBeatIndex ?? 0
            let tick: Int
            if let subdivisionIndex = event.onsetSubdivisionIndex {
                tick = subdivisionIndex * subdivisionTicks
            } else {
                tick = beatIndex * ticksPerBeat
            }
            return BaseChartNote(
                lane: event.lane,
                tick: tick,
                beatIndex: beatIndex,
                subdivisionIndex: event.onsetSubdivisionIndex,
                startSeconds: event.onsetSeconds,
                durationTicks: 0,
                velocity: event.velocity,
                sourceEventID: event.eventID
            )
        }
    }

    private static func nearestAnchor(to onsetSeconds: Double, beatGrid: [BeatGridEvent]) -> BeatGridEvent? {
        beatGrid.min { abs($0.startSeconds - onsetSeconds) < abs($1.startSeconds - onsetSeconds) }
    }

    private static func extractBeatStarts(from raw: RawJSONValue?) -> [Double]? {
        guard let root = raw?.dictionary else { return nil }
        let candidates: [RawJSONValue?] = [root["beats"], root["beatTimes"], root["beat_times"], root["timing"]?.dictionary?["beats"]]
        for candidate in candidates {
            if let values = candidate?.array?.compactMap({ rawDouble($0) }), !values.isEmpty {
                return values
            }
            if let objects = candidate?.array?.compactMap({ $0.dictionary }), !objects.isEmpty {
                let values = objects.compactMap { rawDouble($0["startSeconds"] ?? $0["start_seconds"] ?? $0["time"] ?? $0["timestamp"]) }
                if !values.isEmpty { return values }
            }
        }
        return nil
    }

    private static func extractRawDrumEventCandidates(from raw: RawJSONValue?) -> [[String: RawJSONValue]] {
        guard let root = raw?.dictionary else { return [] }
        let candidateArrays: [RawJSONValue?] = [root["drumEvents"], root["drum_events"], root["events"], root["hits"], root["notes"]]
        for candidate in candidateArrays {
            let values = candidate?.array?.compactMap { $0.dictionary } ?? []
            if !values.isEmpty { return values }
        }
        return []
    }

    private static func mapLane(_ rawValue: RawJSONValue?) -> DrumLane? {
        guard let raw = rawString(rawValue)?.lowercased().replacingOccurrences(of: "-", with: "_") else { return nil }
        switch raw {
        case "kick", "bd", "bass_drum": return .kick
        case "snare", "sd": return .snare
        case "hihat_closed", "closed_hihat", "closed_hat", "hhc": return .hihatClosed
        case "hihat_open", "open_hihat", "open_hat", "hho": return .hihatOpen
        case "tom_low", "low_tom": return .tomLow
        case "tom_mid", "mid_tom", "tom_medium": return .tomMid
        case "tom_high", "high_tom": return .tomHigh
        case "crash", "crash_cymbal": return .crash
        case "ride", "ride_cymbal": return .ride
        case "clap": return .clap
        case "percussion", "perc": return .percussion
        default: return nil
        }
    }

    private static func rawString(_ value: RawJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string): return string
        case .number(let number): return String(number)
        case .bool(let bool): return String(bool)
        default: return nil
        }
    }

    private static func rawDouble(_ value: RawJSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .number(let number): return number
        case .string(let string): return Double(string)
        default: return nil
        }
    }
}
