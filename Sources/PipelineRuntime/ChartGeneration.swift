import Foundation
import PipelineDomain

struct ChartGenerationOutput {
    let normalized: NormalizedAnalysisContract
    let baseChart: BaseChartContract
}

enum ChartGenerator {
    private static let fallbackSubdivisionsPerBeat = 4
    private static let supportedSubdivisionCandidates = [3, 4, 6, 8]

    static func generate(from analysis: AudioAnalysisContract, generatedAt: Date, normalizedAnalysisArtifactURI: String) -> ChartGenerationOutput {
        let timeSignature = TimeSignature(numerator: 4, denominator: 4)
        let ticksPerBeat = 480
        let beatGrid = makeBeatGrid(from: analysis, timeSignature: timeSignature)
        let drumEventResult = makeDrumEvents(from: analysis, beatGrid: beatGrid)
        let drumEvents = drumEventResult.events
        let measures = makeMeasures(from: beatGrid, timeSignature: timeSignature)
        let warnings = combinedWarnings(for: analysis, beatGrid: beatGrid, drumEventDiagnostics: drumEventResult.diagnostics)
        let detectedSubdivisionCount = inferredSubdivisionsPerBeat(from: beatGrid)
        let usedAnalyzerEvents = drumEvents.contains(where: { !($0.sourceLabel ?? "").hasPrefix("heuristic_") })

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
            note: usedAnalyzerEvents
                ? "Normalized analysis generated from analyzer timing/event output with \(detectedSubdivisionCount)x subdivision anchors per beat."
                : "Heuristic normalization generated from coarse analysis summary with \(detectedSubdivisionCount)x fallback subdivision anchors per beat."
        )

        let notes = makeChartNotes(from: drumEvents, ticksPerBeat: ticksPerBeat, beatGrid: beatGrid)
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
                difficulty: usedAnalyzerEvents ? "prototype" : "normal",
                measures: measures,
                notes: notes
            ),
            warnings: warnings,
            note: usedAnalyzerEvents
                ? "Base chart generated from analyzer timing and mapped drum-event candidates using \(detectedSubdivisionCount)x quantization."
                : "Heuristic base chart intended as a deterministic playable scaffold using \(detectedSubdivisionCount)x fallback quantization."
        )

        return ChartGenerationOutput(normalized: normalized, baseChart: baseChart)
    }

    private struct DrumEventDiagnostics {
        let usedFallback: Bool
        let totalCandidates: Int
        let mappedCandidates: Int
        let droppedMissingOnset: Int
        let droppedUnknownLane: Int
        let maxQuantizationErrorSeconds: Double?
        let laneMappingsUsed: Set<DrumLane>
    }

    private struct DrumEventResult {
        let events: [DetectedDrumEvent]
        let diagnostics: DrumEventDiagnostics
    }

    private static func combinedWarnings(for analysis: AudioAnalysisContract, beatGrid: [BeatGridEvent], drumEventDiagnostics: DrumEventDiagnostics) -> [String] {
        var warnings = analysis.warnings
        if analysis.analysis.estimatedTempoBPM == nil {
            warnings.append("No analyzer tempo found; fallback 120 BPM grid used for chart-generation staging.")
        }
        if analysis.analysis.durationSeconds == nil {
            warnings.append("No analyzer duration found; normalized beat grid may be truncated.")
        }
        if beatGrid.isEmpty {
            warnings.append("No usable beat grid anchors were available; chart timing may be incomplete.")
        }
        if drumEventDiagnostics.usedFallback {
            warnings.append("Analyzer did not provide usable drum-event candidates; emitted heuristic playable groove instead.")
        }
        if drumEventDiagnostics.droppedMissingOnset > 0 {
            warnings.append("Dropped \(drumEventDiagnostics.droppedMissingOnset) drum-event candidates without onset timing.")
        }
        if drumEventDiagnostics.droppedUnknownLane > 0 {
            warnings.append("Dropped \(drumEventDiagnostics.droppedUnknownLane) drum-event candidates with unmapped lanes.")
        }
        if drumEventDiagnostics.totalCandidates > 0, drumEventDiagnostics.mappedCandidates < drumEventDiagnostics.totalCandidates {
            warnings.append("Mapped \(drumEventDiagnostics.mappedCandidates) of \(drumEventDiagnostics.totalCandidates) analyzer drum-event candidates into gameplay lanes.")
        }
        if let maxError = drumEventDiagnostics.maxQuantizationErrorSeconds, maxError > 0.05 {
            warnings.append(String(format: "Quantization drift reached %.3f seconds at the furthest mapped drum event.", maxError))
        }
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }

    private static func makeBeatGrid(from analysis: AudioAnalysisContract, timeSignature: TimeSignature) -> [BeatGridEvent] {
        if let beatStarts = extractBeatStarts(from: analysis.rawAnalyzerOutput), !beatStarts.isEmpty {
            let sortedBeatStarts = beatStarts.sorted()
            let analyzerCandidates = extractRawDrumEventCandidates(from: analysis.rawAnalyzerOutput)
            let subdivisionsPerBeat = inferredAnalyzerSubdivisions(from: analysis.rawAnalyzerOutput)
                ?? inferredSubdivisionsFromAnalyzerEvents(beatStarts: sortedBeatStarts, candidates: analyzerCandidates)
                ?? fallbackSubdivisionsPerBeat
            return beatGridFromBeatStarts(
                sortedBeatStarts,
                subdivisionStarts: extractSubdivisionStarts(from: analysis.rawAnalyzerOutput) ?? [],
                downbeatStarts: extractDownbeatStarts(from: analysis.rawAnalyzerOutput) ?? [],
                tempoBPM: analysis.analysis.estimatedTempoBPM,
                confidence: analysis.analysis.confidence,
                timeSignature: timeSignature,
                subdivisionsPerBeat: subdivisionsPerBeat
            )
        }

        let tempo = analysis.analysis.estimatedTempoBPM ?? 120
        let secondsPerBeat = 60.0 / max(tempo, 1)
        let downbeatOffset = max(analysis.analysis.downbeatOffsetSeconds ?? 0, 0)
        let duration = max(analysis.analysis.durationSeconds ?? downbeatOffset + secondsPerBeat * 4, downbeatOffset + secondsPerBeat)
        let rawBeatCount = Int(ceil((duration - downbeatOffset) / secondsPerBeat))
        let beatCount = max(rawBeatCount, 1)
        let subdivisionsPerBeat = fallbackSubdivisionsPerBeat

        var beatGrid: [BeatGridEvent] = []
        beatGrid.reserveCapacity(beatCount * subdivisionsPerBeat)

        for beatIndex in 0..<beatCount {
            let beatStart = downbeatOffset + Double(beatIndex) * secondsPerBeat
            let barIndex = beatIndex / timeSignature.numerator
            let beatInBar = (beatIndex % timeSignature.numerator) + 1
            for subdivisionInBeat in 0..<subdivisionsPerBeat {
                let subdivisionIndex = beatIndex * subdivisionsPerBeat + subdivisionInBeat
                let startSeconds = beatStart + Double(subdivisionInBeat) / Double(subdivisionsPerBeat) * secondsPerBeat
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

    private static func beatGridFromBeatStarts(
        _ beatStarts: [Double],
        subdivisionStarts: [Double],
        downbeatStarts: [Double],
        tempoBPM: Double?,
        confidence: Double?,
        timeSignature: TimeSignature,
        subdivisionsPerBeat: Int
    ) -> [BeatGridEvent] {
        guard !beatStarts.isEmpty else { return [] }
        let usableSubdivisions = max(1, min(subdivisionsPerBeat, 8))
        let estimatedFinalBeatDuration = estimateFinalBeatDuration(from: beatStarts, tempoBPM: tempoBPM)
        let normalizedDownbeats = normalizeStarts(downbeatStarts)
        let normalizedSubdivisionStarts = normalizeStarts(subdivisionStarts)
        var beatGrid: [BeatGridEvent] = []
        beatGrid.reserveCapacity(beatStarts.count * usableSubdivisions)
        var currentBarIndex = -1
        var currentBeatInBar = timeSignature.numerator
        var absoluteSubdivisionIndex = 0

        for (beatIndex, startSeconds) in beatStarts.enumerated() {
            let nextStart = beatIndex + 1 < beatStarts.count ? beatStarts[beatIndex + 1] : startSeconds + estimatedFinalBeatDuration
            let beatDuration = max(nextStart - startSeconds, estimatedFinalBeatDuration / Double(usableSubdivisions))
            let isDownbeatBeat = matchesKnownDownbeat(startSeconds: startSeconds, downbeatStarts: normalizedDownbeats)
                || (normalizedDownbeats.isEmpty && beatIndex % timeSignature.numerator == 0)
            if isDownbeatBeat {
                currentBarIndex += 1
                currentBeatInBar = 1
            } else if currentBarIndex < 0 {
                currentBarIndex = beatIndex / timeSignature.numerator
                currentBeatInBar = (beatIndex % timeSignature.numerator) + 1
            } else {
                currentBeatInBar += 1
                if currentBeatInBar > timeSignature.numerator {
                    currentBarIndex += 1
                    currentBeatInBar = 1
                }
            }
            let barIndex = max(currentBarIndex, 0)
            let beatInBar = max(currentBeatInBar, 1)

            let explicitInteriorStarts = normalizedSubdivisionStarts.filter {
                $0 > startSeconds + 0.0005 && $0 < nextStart - 0.0005
            }
            let anchorStarts: [Double]
            if explicitInteriorStarts.isEmpty {
                anchorStarts = (0..<usableSubdivisions).map {
                    startSeconds + Double($0) / Double(usableSubdivisions) * beatDuration
                }
            } else {
                anchorStarts = [startSeconds] + explicitInteriorStarts
            }

            for (subdivisionInBeat, slotStart) in anchorStarts.enumerated() {
                let slotEnd = subdivisionInBeat + 1 < anchorStarts.count ? anchorStarts[subdivisionInBeat + 1] : nextStart
                beatGrid.append(
                    BeatGridEvent(
                        beatIndex: beatIndex,
                        barIndex: barIndex,
                        beatInBar: beatInBar,
                        subdivisionIndex: absoluteSubdivisionIndex,
                        subdivisionInBeat: subdivisionInBeat,
                        startSeconds: slotStart,
                        durationSeconds: max(slotEnd - slotStart, 0),
                        isDownbeat: beatInBar == 1 && subdivisionInBeat == 0,
                        tempoBPM: localTempo(forBeatDuration: beatDuration, fallbackTempoBPM: tempoBPM),
                        timeSignature: subdivisionInBeat == 0 && beatInBar == 1 ? timeSignature : nil,
                        confidence: confidence
                    )
                )
                absoluteSubdivisionIndex += 1
            }
        }

        return beatGrid
    }

    private static func makeDrumEvents(from analysis: AudioAnalysisContract, beatGrid: [BeatGridEvent]) -> DrumEventResult {
        let candidates = extractRawDrumEventCandidates(from: analysis.rawAnalyzerOutput)
        var droppedMissingOnset = 0
        var droppedUnknownLane = 0
        var maxQuantizationError = 0.0
        var observedQuantization = false
        var mappedLanes = Set<DrumLane>()

        let mapped = candidates.enumerated().compactMap { index, candidate -> DetectedDrumEvent? in
            guard let onsetSeconds = rawDouble(
                candidate["onsetSeconds"]
                    ?? candidate["onset_seconds"]
                    ?? candidate["time"]
                    ?? candidate["timestamp"]
                    ?? candidate["timeSeconds"]
                    ?? candidate["time_seconds"]
                    ?? candidate["startSeconds"]
                    ?? candidate["start_seconds"]
            ) else {
                droppedMissingOnset += 1
                return nil
            }
            guard let lane = mapLane(
                candidate["lane"]
                    ?? candidate["label"]
                    ?? candidate["sourceLabel"]
                    ?? candidate["source_label"]
                    ?? candidate["instrument"]
                    ?? candidate["class"]
                    ?? candidate["type"]
                    ?? candidate["name"]
            ) else {
                droppedUnknownLane += 1
                return nil
            }
            let anchor = nearestAnchor(to: onsetSeconds, beatGrid: beatGrid)
            if let anchor {
                observedQuantization = true
                maxQuantizationError = max(maxQuantizationError, abs(anchor.startSeconds - onsetSeconds))
            }
            mappedLanes.insert(lane)
            return DetectedDrumEvent(
                eventID: rawString(candidate["eventID"] ?? candidate["event_id"] ?? candidate["id"]) ?? "evt-\(index)",
                onsetSeconds: onsetSeconds,
                onsetBeatIndex: anchor?.beatIndex,
                onsetSubdivisionIndex: anchor?.subdivisionIndex,
                lane: lane,
                velocity: clampedVelocity(from: candidate["velocity"] ?? candidate["strength"] ?? candidate["amplitude"]),
                sourceLabel: rawString(candidate["sourceLabel"] ?? candidate["source_label"] ?? candidate["label"] ?? candidate["instrument"] ?? candidate["class"] ?? candidate["type"]),
                confidence: rawDouble(candidate["confidence"] ?? candidate["probability"] ?? candidate["score"])
            )
        }

        if !mapped.isEmpty {
            return DrumEventResult(
                events: mapped.sorted {
                    if $0.onsetSeconds == $1.onsetSeconds { return $0.lane.rawValue < $1.lane.rawValue }
                    return $0.onsetSeconds < $1.onsetSeconds
                },
                diagnostics: DrumEventDiagnostics(
                    usedFallback: false,
                    totalCandidates: candidates.count,
                    mappedCandidates: mapped.count,
                    droppedMissingOnset: droppedMissingOnset,
                    droppedUnknownLane: droppedUnknownLane,
                    maxQuantizationErrorSeconds: observedQuantization ? maxQuantizationError : nil,
                    laneMappingsUsed: mappedLanes
                )
            )
        }

        let fallback = heuristicDrumEvents(from: beatGrid, confidence: analysis.analysis.confidence)
        return DrumEventResult(
            events: fallback,
            diagnostics: DrumEventDiagnostics(
                usedFallback: true,
                totalCandidates: candidates.count,
                mappedCandidates: 0,
                droppedMissingOnset: droppedMissingOnset,
                droppedUnknownLane: droppedUnknownLane,
                maxQuantizationErrorSeconds: nil,
                laneMappingsUsed: Set(fallback.map(\.lane))
            )
        )
    }

    private static func heuristicDrumEvents(from beatGrid: [BeatGridEvent], confidence: Double?) -> [DetectedDrumEvent] {
        var events: [DetectedDrumEvent] = []
        for anchor in beatGrid {
            switch anchor.subdivisionInBeat {
            case 0:
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
            case 2:
                events.append(
                    DetectedDrumEvent(
                        onsetSeconds: anchor.startSeconds,
                        onsetBeatIndex: anchor.beatIndex,
                        onsetSubdivisionIndex: anchor.subdivisionIndex,
                        lane: .hihatClosed,
                        velocity: 0.55,
                        sourceLabel: "heuristic_hat_offbeat",
                        confidence: confidence
                    )
                )
            default:
                continue
            }
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

    private static func makeChartNotes(from drumEvents: [DetectedDrumEvent], ticksPerBeat: Int, beatGrid: [BeatGridEvent]) -> [BaseChartNote] {
        let anchorsBySubdivisionIndex = Dictionary(uniqueKeysWithValues: beatGrid.map { ($0.subdivisionIndex, $0) })
        let anchorsByBeatIndex = Dictionary(grouping: beatGrid, by: \.beatIndex).mapValues { $0.sorted { $0.startSeconds < $1.startSeconds } }

        return drumEvents.map { event in
            let beatIndex = event.onsetBeatIndex ?? 0
            let tick = chartTick(
                for: event,
                ticksPerBeat: ticksPerBeat,
                anchorsBySubdivisionIndex: anchorsBySubdivisionIndex,
                anchorsByBeatIndex: anchorsByBeatIndex
            )
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

    private static func chartTick(
        for event: DetectedDrumEvent,
        ticksPerBeat: Int,
        anchorsBySubdivisionIndex: [Int: BeatGridEvent],
        anchorsByBeatIndex: [Int: [BeatGridEvent]]
    ) -> Int {
        let beatIndex = event.onsetBeatIndex ?? 0
        guard
            let subdivisionIndex = event.onsetSubdivisionIndex,
            let anchor = anchorsBySubdivisionIndex[subdivisionIndex],
            let beatAnchors = anchorsByBeatIndex[anchor.beatIndex],
            let beatStart = beatAnchors.first?.startSeconds
        else {
            return beatIndex * ticksPerBeat
        }

        let beatEnd = beatAnchors.last.flatMap { lastAnchor in
            lastAnchor.durationSeconds.map { lastAnchor.startSeconds + $0 }
        } ?? (beatStart + 60.0 / 120.0)
        let beatDuration = max(beatEnd - beatStart, 0.0001)
        let relative = min(max((event.onsetSeconds - beatStart) / beatDuration, 0), 0.999)
        let offsetTicks = Int((relative * Double(ticksPerBeat)).rounded())
        return beatIndex * ticksPerBeat + offsetTicks
    }

    private static func nearestAnchor(to onsetSeconds: Double, beatGrid: [BeatGridEvent]) -> BeatGridEvent? {
        beatGrid.min { abs($0.startSeconds - onsetSeconds) < abs($1.startSeconds - onsetSeconds) }
    }

    private static func extractBeatStarts(from raw: RawJSONValue?) -> [Double]? {
        for root in candidateRootObjects(from: raw) {
            let candidates: [RawJSONValue?] = [
                root["beats"],
                root["beatTimes"],
                root["beat_times"],
                root["timing"]?.dictionary?["beats"],
                root["timing"]?.dictionary?["beatTimes"],
                root["timing"]?.dictionary?["beat_times"]
            ]
            for candidate in candidates {
                let values = extractTimingValues(from: candidate)
                if !values.isEmpty { return normalizeStarts(values) }
            }
        }
        return nil
    }

    private static func extractDownbeatStarts(from raw: RawJSONValue?) -> [Double]? {
        for root in candidateRootObjects(from: raw) {
            let candidates: [RawJSONValue?] = [
                root["downbeats"],
                root["downbeatTimes"],
                root["downbeat_times"],
                root["timing"]?.dictionary?["downbeats"],
                root["timing"]?.dictionary?["downbeatTimes"],
                root["timing"]?.dictionary?["downbeat_times"]
            ]
            for candidate in candidates {
                let values = extractTimingValues(from: candidate)
                if !values.isEmpty { return normalizeStarts(values) }
            }
        }
        return nil
    }

    private static func extractSubdivisionStarts(from raw: RawJSONValue?) -> [Double]? {
        for root in candidateRootObjects(from: raw) {
            let candidates: [RawJSONValue?] = [
                root["subdivisions"],
                root["subdivisionTimes"],
                root["subdivision_times"],
                root["tatums"],
                root["tatumTimes"],
                root["tatum_times"],
                root["timing"]?.dictionary?["subdivisions"],
                root["timing"]?.dictionary?["subdivisionTimes"],
                root["timing"]?.dictionary?["subdivision_times"],
                root["timing"]?.dictionary?["tatums"],
                root["timing"]?.dictionary?["tatumTimes"],
                root["timing"]?.dictionary?["tatum_times"]
            ]
            for candidate in candidates {
                let values = extractTimingValues(from: candidate)
                if !values.isEmpty { return normalizeStarts(values) }
            }
        }
        return nil
    }

    private static func extractRawDrumEventCandidates(from raw: RawJSONValue?) -> [[String: RawJSONValue]] {
        for root in candidateRootObjects(from: raw) {
            let candidateArrays: [RawJSONValue?] = [
                root["drumEvents"],
                root["drum_events"],
                root["events"],
                root["hits"],
                root["notes"],
                root["drums"]?.dictionary?["events"],
                root["drums"]?.dictionary?["hits"],
                root["percussion"]?.dictionary?["events"],
                root["percussion"]?.dictionary?["hits"],
                root["timing"]?.dictionary?["drumEvents"],
                root["timing"]?.dictionary?["drum_events"]
            ]
            for candidate in candidateArrays {
                let values = candidate?.array?.compactMap { $0.dictionary } ?? []
                if !values.isEmpty { return values }
            }
        }
        return []
    }

    private static func inferredAnalyzerSubdivisions(from raw: RawJSONValue?) -> Int? {
        for root in candidateRootObjects(from: raw) {
            let explicit = rawInt(
                root["subdivisionsPerBeat"]
                    ?? root["subdivisions_per_beat"]
                    ?? root["timing"]?.dictionary?["subdivisionsPerBeat"]
                    ?? root["timing"]?.dictionary?["subdivisions_per_beat"]
            )
            if let explicit {
                return max(1, min(explicit, 8))
            }
        }
        return nil
    }

    private static func inferredSubdivisionsFromAnalyzerEvents(beatStarts: [Double], candidates: [[String: RawJSONValue]]) -> Int? {
        guard beatStarts.count >= 2 else { return nil }
        let onsets = candidates.compactMap { candidate in
            rawDouble(
                candidate["onsetSeconds"]
                    ?? candidate["onset_seconds"]
                    ?? candidate["time"]
                    ?? candidate["timestamp"]
                    ?? candidate["timeSeconds"]
                    ?? candidate["time_seconds"]
                    ?? candidate["startSeconds"]
                    ?? candidate["start_seconds"]
            )
        }
        .filter { $0.isFinite && $0 >= beatStarts.first! && $0 <= beatStarts.last! + estimateFinalBeatDuration(from: beatStarts, tempoBPM: nil) }

        guard onsets.count >= 2 else { return nil }

        var bestSubdivision = fallbackSubdivisionsPerBeat
        var bestScore = Double.greatestFiniteMagnitude

        for subdivision in supportedSubdivisionCandidates {
            let score = quantizationErrorScore(onsets: onsets, beatStarts: beatStarts, subdivisionsPerBeat: subdivision)
            if score + 0.0001 < bestScore {
                bestScore = score
                bestSubdivision = subdivision
            }
        }

        return bestScore.isFinite ? bestSubdivision : nil
    }

    private static func quantizationErrorScore(onsets: [Double], beatStarts: [Double], subdivisionsPerBeat: Int) -> Double {
        guard subdivisionsPerBeat > 0 else { return Double.greatestFiniteMagnitude }
        var weightedError = 0.0
        var sampleCount = 0

        for onset in onsets {
            guard let beatIndex = nearestBeatIndex(for: onset, beatStarts: beatStarts) else { continue }
            let beatStart = beatStarts[beatIndex]
            let nextBeatStart = beatIndex + 1 < beatStarts.count
                ? beatStarts[beatIndex + 1]
                : beatStart + estimateFinalBeatDuration(from: beatStarts, tempoBPM: nil)
            let beatDuration = max(nextBeatStart - beatStart, 0.0001)
            let relative = min(max((onset - beatStart) / beatDuration, 0), 1)
            let quantizedStep = (relative * Double(subdivisionsPerBeat)).rounded()
            let quantizedRelative = min(max(quantizedStep / Double(subdivisionsPerBeat), 0), 1)
            weightedError += abs(relative - quantizedRelative)
            sampleCount += 1
        }

        guard sampleCount > 0 else { return Double.greatestFiniteMagnitude }
        return weightedError / Double(sampleCount)
    }

    private static func nearestBeatIndex(for onset: Double, beatStarts: [Double]) -> Int? {
        guard !beatStarts.isEmpty else { return nil }
        if beatStarts.count == 1 { return 0 }

        for index in 0..<(beatStarts.count - 1) {
            let start = beatStarts[index]
            let next = beatStarts[index + 1]
            if onset >= start && onset < next {
                return index
            }
        }

        if onset < beatStarts[0] { return 0 }
        return beatStarts.count - 1
    }

    private static func candidateRootObjects(from raw: RawJSONValue?) -> [[String: RawJSONValue]] {
        guard let root = raw?.dictionary else { return [] }
        var objects: [[String: RawJSONValue]] = [root]
        for key in ["result", "output", "payload", "data", "analysis"] {
            if let nested = root[key]?.dictionary {
                objects.append(nested)
            }
        }
        return objects
    }

    private static func extractTimingValues(from candidate: RawJSONValue?) -> [Double] {
        if let values = candidate?.array?.compactMap({ rawDouble($0) }), !values.isEmpty {
            return values
        }
        if let objects = candidate?.array?.compactMap({ $0.dictionary }), !objects.isEmpty {
            return objects.compactMap {
                rawDouble($0["startSeconds"] ?? $0["start_seconds"] ?? $0["time"] ?? $0["timestamp"] ?? $0["onsetSeconds"] ?? $0["onset_seconds"])
            }
        }
        return []
    }

    private static func normalizeStarts(_ values: [Double]) -> [Double] {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        var deduped: [Double] = []
        for value in sorted {
            if let last = deduped.last, abs(last - value) <= 0.0005 { continue }
            deduped.append(value)
        }
        return deduped
    }

    private static func matchesKnownDownbeat(startSeconds: Double, downbeatStarts: [Double]) -> Bool {
        downbeatStarts.contains { abs($0 - startSeconds) <= 0.0005 }
    }

    private static func inferredSubdivisionsPerBeat(from beatGrid: [BeatGridEvent]) -> Int {
        let maxSubdivisionInBeat = beatGrid.map(\.subdivisionInBeat).max() ?? 0
        return max(maxSubdivisionInBeat + 1, 1)
    }

    private static func estimateFinalBeatDuration(from beatStarts: [Double], tempoBPM: Double?) -> Double {
        let intervals = zip(beatStarts, beatStarts.dropFirst()).map { max($1 - $0, 0.0001) }
        if !intervals.isEmpty {
            return intervals.reduce(0, +) / Double(intervals.count)
        }
        if let tempoBPM, tempoBPM > 0 {
            return 60.0 / tempoBPM
        }
        return 0.5
    }

    private static func localTempo(forBeatDuration beatDuration: Double, fallbackTempoBPM: Double?) -> Double? {
        guard beatDuration > 0 else { return fallbackTempoBPM }
        return 60.0 / beatDuration
    }

    private static func mapLane(_ rawValue: RawJSONValue?) -> DrumLane? {
        guard let raw = normalizedLaneLabel(rawValue) else { return nil }
        switch raw {
        case "kick", "bd", "bass_drum", "bassdrum", "bass_drum_1", "bass_drum_2", "bassdrum_1", "bassdrum_2", "kik": return .kick
        case "snare", "sd", "sn", "rimshot", "cross_stick", "side_stick": return .snare
        case "hihat_closed", "closed_hihat", "closed_hat", "closed_hi_hat", "closed_hihat", "hhc", "hat_closed", "hi_hat_closed", "chh": return .hihatClosed
        case "hihat_open", "open_hihat", "open_hat", "open_hi_hat", "open_hihat", "hho", "hat_open", "hi_hat_open", "ohh": return .hihatOpen
        case "tom_low", "low_tom", "floor_tom", "floortom": return .tomLow
        case "tom_mid", "mid_tom", "middle_tom", "mid_tom_1", "tom_medium": return .tomMid
        case "tom_high", "high_tom", "rack_tom", "racktom": return .tomHigh
        case "crash", "crash_cymbal", "crash_left", "crash_right", "crash_1", "crash_2": return .crash
        case "ride", "ride_cymbal", "ride_bell", "ride_1", "ride_2": return .ride
        case "clap", "handclap", "hand_clap": return .clap
        case "percussion", "perc", "cowbell", "shaker", "tambourine": return .percussion
        default: return nil
        }
    }

    private static func normalizedLaneLabel(_ rawValue: RawJSONValue?) -> String? {
        guard let raw = rawString(rawValue)?.lowercased() else { return nil }
        let collapsed = raw
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return collapsed
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

    private static func rawInt(_ value: RawJSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .number(let number): return Int(number)
        case .string(let string): return Int(string)
        default: return nil
        }
    }

    private static func clampedVelocity(from value: RawJSONValue?) -> Double? {
        guard let raw = rawDouble(value) else { return nil }
        return min(max(raw, 0), 1)
    }
}
