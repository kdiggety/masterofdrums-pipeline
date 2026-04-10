import Foundation
import PipelineDomain

struct ChartGenerationOutput {
    let normalized: NormalizedAnalysisContract
    let baseChart: BaseChartContract
}

enum ChartGenerator {
    private static let fallbackSubdivisionsPerBeat = 4
    private static let supportedSubdivisionCandidates = [3, 4, 6, 8, 12]
    private static let maxClosedHihatPulsePerBeat = 1
    private static let maxHiHatTexturePerBeat = 1
    private static let sparseHatPulseBeatsInBar: Set<Int> = [0]
    private static let backboneConfidenceOverrideThreshold = 0.2

    static func generate(from analysis: AudioAnalysisContract, generatedAt: Date, normalizedAnalysisArtifactURI: String) -> ChartGenerationOutput {
        let timeSignature = TimeSignature(numerator: 4, denominator: 4)
        let ticksPerBeat = 480
        let analyzerBeatStarts = extractBeatStarts(from: analysis.rawAnalyzerOutput)
        let usedAnalyzerTiming = !(analyzerBeatStarts?.isEmpty ?? true)
        let beatGrid = makeBeatGrid(from: analysis, timeSignature: timeSignature)
        let drumEventResult = makeDrumEvents(from: analysis, beatGrid: beatGrid)
        let measures = makeMeasures(from: beatGrid, timeSignature: timeSignature)
        let warnings = combinedWarnings(for: analysis, beatGrid: beatGrid, drumEventResult: drumEventResult, usedAnalyzerTiming: usedAnalyzerTiming)
        let detectedSubdivisionCount = inferredSubdivisionsPerBeat(from: beatGrid)
        let usedAnalyzerEvents = drumEventResult.events.contains(where: { !($0.sourceLabel ?? "").hasPrefix("heuristic_") })
        let sourceProvenance = makeSourceProvenance(from: analysis, drumEventResult: drumEventResult, usedAnalyzerTiming: usedAnalyzerTiming)
        let operatorSummary = makeOperatorSummary(drumEvents: drumEventResult.events, sourceProvenance: sourceProvenance, warnings: warnings)

        let normalizedTimingOffsetSeconds = beatGrid.first(where: { $0.beatIndex == 0 && $0.subdivisionInBeat == 0 })?.startSeconds
            ?? analysis.analysis.downbeatOffsetSeconds

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
                downbeatOffsetSeconds: normalizedTimingOffsetSeconds,
                beatCount: Set(beatGrid.map(\.beatIndex)).count,
                barCount: measures.count,
                drumEventCount: drumEventResult.events.count,
                predominantTimeSignature: timeSignature,
                confidence: analysis.analysis.confidence,
                sourceProvenance: sourceProvenance,
                operatorSummary: operatorSummary
            ),
            beatGrid: beatGrid,
            drumEvents: drumEventResult.events,
            drumEventDiagnostics: drumEventResult.diagnostics,
            warnings: warnings,
            note: usedAnalyzerEvents
                ? "Normalized analysis generated from analyzer-provided timing and analyzer drum-event candidates with \(detectedSubdivisionCount)x subdivision anchors per beat."
                : usedAnalyzerTiming
                    ? "Normalized analysis generated from analyzer-provided timing, while drum events came from heuristicDrumEvents fallback shaping, with \(detectedSubdivisionCount)x subdivision anchors per beat."
                    : "Heuristic normalization generated from coarse analysis summary with \(detectedSubdivisionCount)x fallback subdivision anchors per beat."
        )

        let notes = makeChartNotes(from: normalized.drumEvents, ticksPerBeat: ticksPerBeat, beatGrid: beatGrid)
        let lanes = Array(Set(notes.map { $0.lane })).sorted { $0.rawValue < $1.rawValue }
        let timingOffsetSeconds = beatGrid.first(where: { $0.beatIndex == 0 && $0.subdivisionInBeat == 0 })?.startSeconds
            ?? analysis.analysis.downbeatOffsetSeconds
            ?? 0
        let baseChart = BaseChartContract(
            source: BaseChartSource(
                normalizedAnalysisArtifactURI: normalizedAnalysisArtifactURI,
                sourceType: analysis.source.sourceType,
                sourceURI: analysis.source.sourceURI,
                requestedBy: analysis.source.requestedBy
            ),
            timing: BaseChartTiming(
                bpm: analysis.analysis.estimatedTempoBPM,
                offsetSeconds: timingOffsetSeconds,
                ticksPerBeat: ticksPerBeat,
                timeSignature: timeSignature,
                source: usedAnalyzerTiming ? "generated" : "fallback"
            ),
            chart: BaseChartData(
                generatedAt: generatedAt,
                ticksPerBeat: ticksPerBeat,
                offsetSeconds: timingOffsetSeconds,
                lanes: lanes.isEmpty ? [.kick] : lanes,
                difficulty: usedAnalyzerEvents ? "prototype" : "normal",
                measures: measures,
                notes: notes
            ),
            drumEventDiagnostics: drumEventResult.diagnostics,
            warnings: warnings,
            note: usedAnalyzerEvents
                ? "Base chart generated from analyzer-provided timing and mapped analyzer drum-event candidates using \(detectedSubdivisionCount)x quantization."
                : usedAnalyzerTiming
                    ? "Base chart generated from analyzer-provided timing, while note placement came from heuristicDrumEvents fallback output, using \(detectedSubdivisionCount)x quantization."
                    : "Heuristic base chart intended as a deterministic playable scaffold using \(detectedSubdivisionCount)x fallback quantization."
        )

        return ChartGenerationOutput(normalized: normalized, baseChart: baseChart)
    }

    private struct DrumEventResult {
        let events: [DetectedDrumEvent]
        let diagnostics: DrumEventDiagnostics
        let maxQuantizationErrorSeconds: Double?
        let laneMappingsUsed: Set<DrumLane>
    }

    private static func combinedWarnings(for analysis: AudioAnalysisContract, beatGrid: [BeatGridEvent], drumEventResult: DrumEventResult, usedAnalyzerTiming: Bool) -> [String] {
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
        if drumEventResult.diagnostics.usedFallback {
            if usedAnalyzerTiming {
                warnings.append("Analyzer timing was preserved, but analyzer drum-event candidates were unusable; heuristicDrumEvents supplied the playable drum events instead.")
            } else {
                warnings.append("Analyzer did not provide usable timing or drum-event candidates; emitted heuristic playable groove instead.")
            }
        }
        if drumEventResult.diagnostics.droppedMissingOnsetCount > 0 {
            warnings.append("Dropped \(drumEventResult.diagnostics.droppedMissingOnsetCount) drum-event candidates without onset timing.")
        }
        if drumEventResult.diagnostics.droppedUnknownLaneCount > 0 {
            warnings.append("Dropped \(drumEventResult.diagnostics.droppedUnknownLaneCount) drum-event candidates with unmapped lanes.")
        }
        if drumEventResult.diagnostics.deduplicatedCandidateCount > 0 {
            warnings.append("Collapsed \(drumEventResult.diagnostics.deduplicatedCandidateCount) analyzer drum-event duplicates that landed on the same lane and quantized slot.")
        }
        if drumEventResult.diagnostics.shapingReductionCount > 0 {
            warnings.append("Reduced analyzer-driven drum events by \(drumEventResult.diagnostics.shapingReductionCount) during normalization shaping before base-chart note generation.")
        }
        if drumEventResult.diagnostics.rawCandidateCount > 0, drumEventResult.diagnostics.mappedCandidateCount < drumEventResult.diagnostics.rawCandidateCount {
            warnings.append("Mapped \(drumEventResult.diagnostics.mappedCandidateCount) of \(drumEventResult.diagnostics.rawCandidateCount) analyzer drum-event candidates into gameplay lanes.")
        }
        if usedAnalyzerTiming || drumEventResult.diagnostics.rawCandidateCount > 0 {
            warnings.append("Timing/events split: timing source=\(usedAnalyzerTiming ? "analyzer" : "heuristic"); drum-event source=\(drumEventResult.diagnostics.usedFallback ? "heuristicDrumEvents" : "analyzer").")
        }
        if drumEventResult.diagnostics.rawCandidateCount > 0 {
            warnings.append("Analyzer drum-event diagnostics: raw=\(drumEventResult.diagnostics.rawCandidateCount) mapped=\(drumEventResult.diagnostics.mappedCandidateCount) post-shaping=\(drumEventResult.diagnostics.postShapingEventCount).")
        }
        if let maxError = drumEventResult.maxQuantizationErrorSeconds, maxError > 0.05 {
            warnings.append(String(format: "Quantization drift reached %.3f seconds at the furthest mapped drum event.", maxError))
        }
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }

    private static func makeSourceProvenance(from analysis: AudioAnalysisContract, drumEventResult: DrumEventResult, usedAnalyzerTiming: Bool) -> NormalizedAnalysisSourceProvenance {
        let eventSource = drumEventResult.diagnostics.usedFallback ? "heuristicDrumEvents" : (analysis.analysis.eventProvenance?.eventSource ?? "analyzer")
        let eventBackend = drumEventResult.diagnostics.usedFallback
            ? "heuristicDrumEvents"
            : (analysis.analysis.eventProvenance?.backend ?? analysis.analysis.runtimeBackend)
        return NormalizedAnalysisSourceProvenance(
            timingSource: usedAnalyzerTiming ? "analyzer" : "heuristic",
            timingBackend: analysis.analysis.timingProvenance?.backend ?? analysis.analysis.runtimeSelectedBackend ?? analysis.analysis.runtimeBackend,
            eventSource: eventSource,
            eventBackend: eventBackend,
            eventBackendCommand: drumEventResult.diagnostics.usedFallback ? nil : analysis.analysis.eventProvenance?.backendCommand
        )
    }

    private static func makeOperatorSummary(
        drumEvents: [DetectedDrumEvent],
        sourceProvenance: NormalizedAnalysisSourceProvenance,
        warnings: [String]
    ) -> NormalizedAnalysisOperatorSummary {
        let laneSummary = Dictionary(grouping: drumEvents, by: \.lane)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .joined(separator: " ")
        let confidenceSummary = confidenceBandSummary(for: drumEvents)
        let sourceSummary = [
            "timing=\(sourceProvenance.timingSource)",
            sourceProvenance.timingBackend.map { "timing_backend=\($0)" },
            "events=\(sourceProvenance.eventSource)",
            sourceProvenance.eventBackend.map { "event_backend=\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        let notableWarnings = warnings.filter { warning in
            warning.contains("heuristic") || warning.contains("Dropped ") || warning.contains("Collapsed ") || warning.contains("Reduced ") || warning.contains("Quantization drift")
        }
        let warningSummary = notableWarnings.isEmpty ? nil : notableWarnings.prefix(3).joined(separator: " | ")
        return NormalizedAnalysisOperatorSummary(
            sourceSummary: sourceSummary,
            laneSummary: laneSummary.isEmpty ? "none" : laneSummary,
            confidenceSummary: confidenceSummary,
            warningSummary: warningSummary
        )
    }

    private static func confidenceBandSummary(for drumEvents: [DetectedDrumEvent]) -> String {
        var high = 0
        var medium = 0
        var low = 0
        var unknown = 0
        for event in drumEvents {
            guard let confidence = event.confidence ?? event.velocity else {
                unknown += 1
                continue
            }
            switch confidence {
            case 0.8...: high += 1
            case 0.5..<0.8: medium += 1
            default: low += 1
            }
        }
        return "high=\(high) medium=\(medium) low=\(low) unknown=\(unknown)"
    }

    private static func makeBeatGrid(from analysis: AudioAnalysisContract, timeSignature: TimeSignature) -> [BeatGridEvent] {
        if let beatStarts = extractBeatStarts(from: analysis.rawAnalyzerOutput), !beatStarts.isEmpty {
            let analyzerCandidates = extractRawDrumEventCandidates(from: analysis.rawAnalyzerOutput)
            let normalizedDownbeatStarts = normalizeLoopDownbeats(
                extractDownbeatStarts(from: analysis.rawAnalyzerOutput) ?? [],
                tempoBPM: analysis.analysis.estimatedTempoBPM,
                timeSignature: timeSignature
            )
            let repairedBeatStarts = normalizeLoopBeatStarts(
                beatStarts,
                downbeatStarts: normalizedDownbeatStarts,
                tempoBPM: analysis.analysis.estimatedTempoBPM,
                timeSignature: timeSignature
            )
            let subdivisionsPerBeat = inferredAnalyzerSubdivisions(from: analysis.rawAnalyzerOutput)
                ?? inferredSubdivisionsFromAnalyzerEvents(beatStarts: repairedBeatStarts, candidates: analyzerCandidates)
                ?? fallbackSubdivisionsPerBeat
            return beatGridFromBeatStarts(
                repairedBeatStarts,
                subdivisionStarts: extractSubdivisionStarts(from: analysis.rawAnalyzerOutput) ?? [],
                downbeatStarts: normalizedDownbeatStarts,
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
        let usableSubdivisions = max(1, min(subdivisionsPerBeat, 12))
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
            let onsetValue = firstValue(
                in: candidate,
                keys: [
                    "onsetSeconds",
                    "onset_seconds",
                    "time",
                    "timestamp",
                    "timeSeconds",
                    "time_seconds",
                    "startSeconds",
                    "start_seconds",
                    "position",
                    "offset",
                    "onset"
                ]
            )
            guard let onsetSeconds = timingValue(from: onsetValue) else {
                droppedMissingOnset += 1
                return nil
            }
            guard let lane = mapLane(eventLaneValue(from: candidate)) else {
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
                sourceLabel: rawString(eventLaneValue(from: candidate) ?? candidate["sourceLabel"] ?? candidate["source_label"]),
                confidence: rawDouble(candidate["confidence"] ?? candidate["probability"] ?? candidate["score"])
            )
        }

        let reduced = reduceMappedDrumEvents(mapped)

        if !reduced.events.isEmpty {
            return DrumEventResult(
                events: reduced.events,
                diagnostics: DrumEventDiagnostics(
                    rawCandidateCount: candidates.count,
                    mappedCandidateCount: mapped.count,
                    postShapingEventCount: reduced.events.count,
                    usedFallback: false,
                    droppedMissingOnsetCount: droppedMissingOnset,
                    droppedUnknownLaneCount: droppedUnknownLane,
                    deduplicatedCandidateCount: reduced.deduplicatedCandidates,
                    shapingReductionCount: max(mapped.count - reduced.events.count, 0)
                ),
                maxQuantizationErrorSeconds: observedQuantization ? maxQuantizationError : nil,
                laneMappingsUsed: mappedLanes
            )
        }

        let fallback = heuristicDrumEvents(from: beatGrid, confidence: analysis.analysis.confidence)
        return DrumEventResult(
            events: fallback,
            diagnostics: DrumEventDiagnostics(
                rawCandidateCount: candidates.count,
                mappedCandidateCount: mapped.count,
                postShapingEventCount: fallback.count,
                usedFallback: true,
                droppedMissingOnsetCount: droppedMissingOnset,
                droppedUnknownLaneCount: droppedUnknownLane,
                deduplicatedCandidateCount: 0,
                shapingReductionCount: 0
            ),
            maxQuantizationErrorSeconds: nil,
            laneMappingsUsed: Set(fallback.map { $0.lane })
        )
    }

    private struct ReducedMappedEvents {
        let events: [DetectedDrumEvent]
        let deduplicatedCandidates: Int
    }

    private static func reduceMappedDrumEvents(_ mapped: [DetectedDrumEvent]) -> ReducedMappedEvents {
        guard !mapped.isEmpty else {
            return ReducedMappedEvents(events: [], deduplicatedCandidates: 0)
        }

        let grouped = Dictionary(grouping: mapped) { event in
            "\(event.onsetSubdivisionIndex ?? -1)|\(event.onsetBeatIndex ?? -1)|\(event.lane.rawValue)"
        }

        var deduplicatedCandidates = 0
        let reduced = grouped.values.compactMap { group -> DetectedDrumEvent? in
            guard let best = group.max(by: isPreferredDuplicate(_:_:)) else { return nil }
            deduplicatedCandidates += max(group.count - 1, 0)
            return best
        }
        .sorted {
            if $0.onsetSeconds == $1.onsetSeconds { return $0.lane.rawValue < $1.lane.rawValue }
            return $0.onsetSeconds < $1.onsetSeconds
        }

        let shaped = shapeDetectedDrumEvents(reduced)
        deduplicatedCandidates += max(reduced.count - shaped.count, 0)

        return ReducedMappedEvents(events: shaped, deduplicatedCandidates: deduplicatedCandidates)
    }

    private static func isPreferredDuplicate(_ lhs: DetectedDrumEvent, _ rhs: DetectedDrumEvent) -> Bool {
        let lhsConfidence = lhs.confidence ?? -1
        let rhsConfidence = rhs.confidence ?? -1
        if lhsConfidence != rhsConfidence { return lhsConfidence < rhsConfidence }

        let lhsVelocity = lhs.velocity ?? -1
        let rhsVelocity = rhs.velocity ?? -1
        if lhsVelocity != rhsVelocity { return lhsVelocity < rhsVelocity }

        if lhs.onsetSeconds != rhs.onsetSeconds { return lhs.onsetSeconds < rhs.onsetSeconds }
        return lhs.eventID < rhs.eventID
    }

    private static let backboneFamilyLanes: Set<DrumLane> = [.kick, .snare]
    private static let accentLanes: Set<DrumLane> = [.crash, .ride]
    private static let hihatFamilyLanes: Set<DrumLane> = [.hihatClosed, .hihatOpen]
    private static let tomLanes: Set<DrumLane> = [.tomHigh, .tomMid, .tomLow]

    private struct BeatShapingContext {
        let beatIndex: Int
        let isTomHeavy: Bool
        let isFillLike: Bool
        let continuesTomMotion: Bool
        let endsFillPhrase: Bool
    }

    private static func shapeDetectedDrumEvents(_ events: [DetectedDrumEvent]) -> [DetectedDrumEvent] {
        guard !events.isEmpty else { return [] }

        let groupedByBeat = Dictionary(grouping: events) { $0.onsetBeatIndex ?? -1 }
        let sortedBeatIndices = groupedByBeat.keys.sorted()
        let beatContexts = makeBeatShapingContexts(groupedByBeat: groupedByBeat, sortedBeatIndices: sortedBeatIndices)

        return sortedBeatIndices.flatMap { beatIndex -> [DetectedDrumEvent] in
            guard let beatEvents = groupedByBeat[beatIndex], let context = beatContexts[beatIndex] else { return [] }

            let backboneEvents = beatEvents
                .filter { backboneFamilyLanes.contains($0.lane) }
                .sorted { lhs, rhs in
                    let lhsPriority = backbonePriority(lhs, context: context)
                    let rhsPriority = backbonePriority(rhs, context: context)
                    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                    return eventPreferenceSort(lhs, rhs)
                }

            let accentEvents = beatEvents
                .filter { accentLanes.contains($0.lane) }
                .sorted(by: eventPreferenceSort)

            let hihats = beatEvents
                .filter { hihatFamilyLanes.contains($0.lane) }
                .sorted { lhs, rhs in
                    let lhsPriority = hihatSubdivisionPriority(lhs.onsetSubdivisionIndex, beatIndex: beatIndex)
                    let rhsPriority = hihatSubdivisionPriority(rhs.onsetSubdivisionIndex, beatIndex: beatIndex)
                    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                    return eventPreferenceSort(lhs, rhs)
                }

            let supportingLanes = beatEvents
                .filter { !backboneFamilyLanes.contains($0.lane) && !accentLanes.contains($0.lane) && !hihatFamilyLanes.contains($0.lane) }
                .sorted(by: eventPreferenceSort)

            let selectedBackbone = preferredBackboneEvents(from: backboneEvents, context: context)
            let selectedAccent = preferredAccent(from: accentEvents, context: context, backbone: selectedBackbone.first)
            let keptHihats = selectHiHats(from: hihats, context: context, backbone: selectedBackbone.first, accent: selectedAccent)

            return (selectedBackbone + [selectedAccent].compactMap { $0 } + keptHihats + supportingLanes).sorted(by: eventPreferenceSort)
        }
    }

    private static func makeBeatShapingContexts(groupedByBeat: [Int: [DetectedDrumEvent]], sortedBeatIndices: [Int]) -> [Int: BeatShapingContext] {
        func tomCount(for beatIndex: Int) -> Int {
            groupedByBeat[beatIndex]?.filter { tomLanes.contains($0.lane) }.count ?? 0
        }

        func nonHatCount(for beatIndex: Int) -> Int {
            groupedByBeat[beatIndex]?.filter { !hihatFamilyLanes.contains($0.lane) }.count ?? 0
        }

        var contexts: [Int: BeatShapingContext] = [:]
        for (position, beatIndex) in sortedBeatIndices.enumerated() {
            let previousBeatIndex = position > 0 ? sortedBeatIndices[position - 1] : nil
            let nextBeatIndex = position + 1 < sortedBeatIndices.count ? sortedBeatIndices[position + 1] : nil
            let currentTomCount = tomCount(for: beatIndex)
            let previousTomCount = previousBeatIndex.map(tomCount(for:)) ?? 0
            let nextTomCount = nextBeatIndex.map(tomCount(for:)) ?? 0
            let isTomHeavy = currentTomCount > 0
            let isFillLike = currentTomCount > 0 && (nonHatCount(for: beatIndex) >= 2 || previousTomCount > 0 || nextTomCount > 0)
            let continuesTomMotion = (previousTomCount > 0) || (nextTomCount > 0)
            let endsFillPhrase = currentTomCount > 0 && nextTomCount == 0
            contexts[beatIndex] = BeatShapingContext(
                beatIndex: beatIndex,
                isTomHeavy: isTomHeavy,
                isFillLike: isFillLike,
                continuesTomMotion: continuesTomMotion,
                endsFillPhrase: endsFillPhrase
            )
        }
        return contexts
    }

    private static func hihatSubdivisionPriority(_ subdivisionIndex: Int?, beatIndex: Int) -> Int {
        guard let subdivisionIndex else { return Int.max }
        switch subdivisionIndex % max(fallbackSubdivisionsPerBeat, 1) {
        case 0: return 0
        case 2: return 1
        case 1, 3: return prefersTextureOnBeat(beatIndex) ? 2 : 4
        default: return 5
        }
    }

    private static func backbonePriority(_ event: DetectedDrumEvent, context: BeatShapingContext) -> Int {
        if context.isFillLike {
            switch event.lane {
            case .kick: return 0
            case .snare: return 1
            default: return 3
            }
        }

        let beatInBar = (((context.beatIndex % 4) + 4) % 4) + 1
        switch event.lane {
        case .snare:
            return (beatInBar == 2 || beatInBar == 4) ? 0 : 2
        case .kick:
            return (beatInBar == 1 || beatInBar == 3) ? 0 : 1
        default:
            return 3
        }
    }

    private static func preferredBackboneEvents(from backboneEvents: [DetectedDrumEvent], context: BeatShapingContext) -> [DetectedDrumEvent] {
        guard !backboneEvents.isEmpty else { return [] }

        let groupedBySubdivision = Dictionary(grouping: backboneEvents) { $0.onsetSubdivisionIndex ?? Int.min }
        let orderedSubdivisionKeys = groupedBySubdivision.keys.sorted()

        return orderedSubdivisionKeys.compactMap { subdivisionKey in
            guard let subdivisionEvents = groupedBySubdivision[subdivisionKey], let prioritized = subdivisionEvents.first else {
                return nil
            }
            guard subdivisionEvents.count > 1 else { return prioritized }

            let strongest = subdivisionEvents.max { lhs, rhs in
                eventStrength(lhs) < eventStrength(rhs)
            } ?? prioritized

            let prioritizedStrength = eventStrength(prioritized)
            let strongestStrength = eventStrength(strongest)
            if strongest.eventID != prioritized.eventID,
               strongestStrength - prioritizedStrength >= backboneConfidenceOverrideThreshold {
                return strongest
            }

            let samePriorityAlternatives = subdivisionEvents.filter {
                backbonePriority($0, context: context) == backbonePriority(prioritized, context: context)
            }
            return samePriorityAlternatives.sorted(by: eventPreferenceSort).first ?? prioritized
        }
    }

    private static func preferredAccent(from accents: [DetectedDrumEvent], context: BeatShapingContext, backbone: DetectedDrumEvent?) -> DetectedDrumEvent? {
        guard !accents.isEmpty else { return nil }
        if context.isFillLike && (context.endsFillPhrase || context.continuesTomMotion || backbone?.lane == .kick) {
            return accents.first
        }
        if backbone?.lane == .snare {
            return nil
        }
        if context.beatIndex >= 0 && (context.beatIndex % 4) == 0 {
            return accents.first
        }
        return backbone == nil ? accents.first : nil
    }

    private static func selectHiHats(
        from hats: [DetectedDrumEvent],
        context: BeatShapingContext,
        backbone: DetectedDrumEvent?,
        accent: DetectedDrumEvent?
    ) -> [DetectedDrumEvent] {
        let uniqueHihats = deduplicateHiHatsBySubdivision(hats)
        guard !uniqueHihats.isEmpty else { return [] }

        let hasKickLikeAnchor = backbone?.lane == .kick || accent?.lane == .crash
        let shouldKeepPulse = !context.isTomHeavy && (hasKickLikeAnchor || prefersSparseHatPulseWithoutAnchor(context.beatIndex))

        let openAccent = preferredOpenHiHatAccent(from: uniqueHihats, hasKickLikeAnchor: hasKickLikeAnchor)
        let pulseCandidates = uniqueHihats.filter { event in
            event.lane == .hihatClosed && event.eventID != openAccent?.eventID
        }

        var kept: [DetectedDrumEvent] = shouldKeepPulse ? Array(pulseCandidates.prefix(maxClosedHihatPulsePerBeat)) : []
        if let openAccent,
           !context.isTomHeavy,
           !kept.contains(where: { $0.eventID == openAccent.eventID }) {
            kept.append(openAccent)
        }

        guard hasKickLikeAnchor, !context.isTomHeavy, prefersTextureOnBeat(context.beatIndex) else {
            return kept.sorted(by: eventPreferenceSort)
        }

        let textureCandidates = uniqueHihats.filter { event in
            guard let subdivisionIndex = event.onsetSubdivisionIndex else { return false }
            guard event.lane == .hihatClosed else { return false }
            guard !kept.contains(where: { $0.eventID == event.eventID }) else { return false }
            switch subdivisionIndex % max(fallbackSubdivisionsPerBeat, 1) {
            case 1, 3: return true
            default: return false
            }
        }

        kept.append(contentsOf: textureCandidates.sorted(by: eventPreferenceSort).prefix(maxHiHatTexturePerBeat))
        return Array(kept.sorted(by: eventPreferenceSort).prefix(maxClosedHihatPulsePerBeat + maxHiHatTexturePerBeat + (openAccent == nil ? 0 : 1)))
    }

    private static func prefersTextureOnBeat(_ beatIndex: Int) -> Bool {
        let beatInBar = ((beatIndex % 4) + 4) % 4
        return beatInBar == 0 || beatInBar == 2
    }

    private static func prefersSparseHatPulseWithoutAnchor(_ beatIndex: Int) -> Bool {
        sparseHatPulseBeatsInBar.contains(((beatIndex % 4) + 4) % 4)
    }

    private static func deduplicateHiHatsBySubdivision(_ hats: [DetectedDrumEvent]) -> [DetectedDrumEvent] {
        var bestBySubdivision: [Int: DetectedDrumEvent] = [:]
        for hat in hats {
            guard let subdivision = hat.onsetSubdivisionIndex else { continue }
            guard let existing = bestBySubdivision[subdivision] else {
                bestBySubdivision[subdivision] = hat
                continue
            }
            if prefersHiHatCandidate(hat, over: existing) {
                bestBySubdivision[subdivision] = hat
            }
        }

        return bestBySubdivision.values.sorted(by: eventPreferenceSort)
    }

    private static func prefersHiHatCandidate(_ candidate: DetectedDrumEvent, over existing: DetectedDrumEvent) -> Bool {
        if candidate.lane != existing.lane {
            return candidate.lane == .hihatOpen
        }
        return eventPreferenceSort(candidate, existing)
    }

    private static func preferredOpenHiHatAccent(from hats: [DetectedDrumEvent], hasKickLikeAnchor: Bool) -> DetectedDrumEvent? {
        let openHats = hats.filter { $0.lane == .hihatOpen }
        guard !openHats.isEmpty else { return nil }
        if hasKickLikeAnchor {
            return openHats.sorted(by: eventPreferenceSort).first
        }
        return openHats.first { ($0.onsetSubdivisionIndex ?? 0) % max(fallbackSubdivisionsPerBeat, 1) == 0 }
            ?? openHats.sorted(by: eventPreferenceSort).first
    }

    private static func eventStrength(_ event: DetectedDrumEvent) -> Double {
        event.confidence ?? event.velocity ?? 0
    }

    private static func eventPreferenceSort(_ lhs: DetectedDrumEvent, _ rhs: DetectedDrumEvent) -> Bool {
        if lhs.onsetSeconds != rhs.onsetSeconds { return lhs.onsetSeconds < rhs.onsetSeconds }
        let lhsConfidence = lhs.confidence ?? lhs.velocity ?? 0
        let rhsConfidence = rhs.confidence ?? rhs.velocity ?? 0
        if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
        return lhs.lane.rawValue < rhs.lane.rawValue
    }

    private static func heuristicDrumEvents(from beatGrid: [BeatGridEvent], confidence: Double?) -> [DetectedDrumEvent] {
        var events: [DetectedDrumEvent] = []
        for anchor in beatGrid {
            switch anchor.subdivisionInBeat {
            case 0:
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
                    mainLane = .kick
                    velocity = 0.76
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

                if anchor.beatInBar == 1 || anchor.beatInBar == 3 {
                    events.append(
                        DetectedDrumEvent(
                            onsetSeconds: anchor.startSeconds,
                            onsetBeatIndex: anchor.beatIndex,
                            onsetSubdivisionIndex: anchor.subdivisionIndex,
                            lane: .hihatClosed,
                            velocity: anchor.isDownbeat ? 0.68 : 0.58,
                            sourceLabel: "heuristic_backbeat_hat",
                            confidence: confidence
                        )
                    )
                }
            case 2:
                guard anchor.beatInBar == 3 else { continue }
                events.append(
                    DetectedDrumEvent(
                        onsetSeconds: anchor.startSeconds,
                        onsetBeatIndex: anchor.beatIndex,
                        onsetSubdivisionIndex: anchor.subdivisionIndex,
                        lane: .hihatClosed,
                        velocity: 0.5,
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
        let quantizedRelative = min(max((anchor.startSeconds - beatStart) / beatDuration, 0), 0.999)
        let offsetTicks = Int((quantizedRelative * Double(ticksPerBeat)).rounded())
        return beatIndex * ticksPerBeat + offsetTicks
    }

    private static func nearestAnchor(to onsetSeconds: Double, beatGrid: [BeatGridEvent]) -> BeatGridEvent? {
        guard !beatGrid.isEmpty else { return nil }

        let beatAnchors = Dictionary(grouping: beatGrid, by: \.beatIndex)
        let sortedBeatIndices = beatAnchors.keys.sorted()

        for (position, beatIndex) in sortedBeatIndices.enumerated() {
            guard let anchors = beatAnchors[beatIndex]?.sorted(by: { $0.startSeconds < $1.startSeconds }),
                  let beatStart = anchors.first?.startSeconds else {
                continue
            }
            let beatEnd: Double = {
                if position + 1 < sortedBeatIndices.count,
                   let nextBeatStart = beatAnchors[sortedBeatIndices[position + 1]]?.sorted(by: { $0.startSeconds < $1.startSeconds }).first?.startSeconds {
                    return nextBeatStart
                }
                if let last = anchors.last, let duration = last.durationSeconds {
                    return last.startSeconds + duration
                }
                return beatStart + 60.0 / 120.0
            }()

            if onsetSeconds >= beatStart && onsetSeconds < beatEnd {
                return anchors.min { abs($0.startSeconds - onsetSeconds) < abs($1.startSeconds - onsetSeconds) }
            }
        }

        return beatGrid.min { abs($0.startSeconds - onsetSeconds) < abs($1.startSeconds - onsetSeconds) }
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
                root["drumEventCandidates"],
                root["drum_event_candidates"],
                root["events"],
                root["hits"],
                root["notes"],
                root["candidates"],
                root["drums"]?.dictionary?["events"],
                root["drums"]?.dictionary?["hits"],
                root["drums"]?.dictionary?["candidates"],
                root["percussion"]?.dictionary?["events"],
                root["percussion"]?.dictionary?["hits"],
                root["percussion"]?.dictionary?["candidates"],
                root["timing"]?.dictionary?["drumEvents"],
                root["timing"]?.dictionary?["drum_events"],
                root["timing"]?.dictionary?["events"],
                root["tracks"],
                root["instruments"],
                root["predictions"],
                root["detections"],
                root["transcription"]?.dictionary?["events"],
                root["transcription"]?.dictionary?["hits"]
            ]
            for candidate in candidateArrays {
                let values = extractEventObjects(from: candidate)
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
                return max(1, min(explicit, 12))
            }
        }
        return nil
    }

    private static func inferredSubdivisionsFromAnalyzerEvents(beatStarts: [Double], candidates: [[String: RawJSONValue]]) -> Int? {
        guard beatStarts.count >= 2 else { return nil }
        let onsets = candidates.compactMap { candidate in
            timingValue(from: .object(candidate))
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
        let interestingKeys: Set<String> = [
            "result", "output", "payload", "data", "analysis", "response", "prediction", "timing", "drums",
            "percussion", "tracks", "track", "events", "drumEvents", "drum_events", "drumEventCandidates",
            "drum_event_candidates", "candidates", "hits", "notes", "transcription", "detections"
        ]

        var ordered: [[String: RawJSONValue]] = []
        var seen = Set<String>()

        func append(_ object: [String: RawJSONValue]) {
            let key = object.keys.sorted().joined(separator: "|")
            guard seen.insert(key).inserted else { return }
            ordered.append(object)
        }

        func visit(_ value: RawJSONValue, preferred: Bool) {
            switch value {
            case .object(let object):
                if preferred {
                    append(object)
                }
                for (key, nested) in object {
                    visit(nested, preferred: preferred || interestingKeys.contains(key))
                }
            case .array(let array):
                for nested in array {
                    visit(nested, preferred: preferred)
                }
            default:
                break
            }
        }

        visit(.object(root), preferred: true)
        return ordered
    }

    private static func extractTimingValues(from candidate: RawJSONValue?) -> [Double] {
        if let values = candidate?.array?.compactMap({ timingValue(from: $0) }), !values.isEmpty {
            return values
        }
        if let value = timingValue(from: candidate) {
            return [value]
        }
        return []
    }

    private static func firstValue(
        in object: [String: RawJSONValue],
        keys: [String]
    ) -> RawJSONValue? {
        for key in keys {
            if let value = object[key] {
                return value
            }
        }
        return nil
    }

    private static func extractEventObjects(from candidate: RawJSONValue?) -> [[String: RawJSONValue]] {
        guard let candidate else { return [] }

        switch candidate {
        case .array(let values):
            return values.flatMap { extractEventObjects(from: $0) }
        case .object(let dictionary):
            if let nested = dictionary["event"]?.dictionary {
                return [dictionary.merging(nested) { _, nested in nested }]
            }
            if let nested = dictionary["hit"]?.dictionary {
                return [dictionary.merging(nested) { _, nested in nested }]
            }
            if let nested = dictionary["drum"]?.dictionary {
                return [dictionary.merging(nested) { _, nested in nested }]
            }
            if eventLaneValue(from: dictionary) != nil || timingValue(from: .object(dictionary)) != nil {
                return [dictionary]
            }
            let nestedKeys = ["items", "events", "hits", "notes", "candidates", "drumEvents", "drum_events", "tracks", "instruments", "predictions", "detections", "children"]
            for key in nestedKeys {
                let nested = extractEventObjects(from: dictionary[key])
                if !nested.isEmpty { return nested }
            }
            for value in dictionary.values {
                let nested = extractEventObjects(from: value)
                if !nested.isEmpty { return nested }
            }
            return []
        default:
            return []
        }
    }

    private static func timingValue(from value: RawJSONValue?) -> Double? {
        guard let value else { return nil }
        if let direct = rawDouble(value) {
            return direct
        }
        guard let object = value.dictionary else { return nil }

        let directValue = firstValue(
            in: object,
            keys: [
                "startSeconds",
                "start_seconds",
                "time",
                "timestamp",
                "seconds",
                "offsetSeconds",
                "offset_seconds",
                "onsetSeconds",
                "onset_seconds"
            ]
        )
        if let direct = rawDouble(directValue) {
            return direct
        }

        for nestedKey in ["time", "start", "position", "offset", "onset"] {
            if let nested = object[nestedKey]?.dictionary,
               let direct = rawDouble(
                   nested["seconds"]
                    ?? nested["timeSeconds"]
                    ?? nested["time_seconds"]
                    ?? nested["startSeconds"]
                    ?? nested["start_seconds"]
                    ?? nested["offsetSeconds"]
                    ?? nested["offset_seconds"]
                    ?? nested["value"]
               ) {
                return direct
            }
        }
        return nil
    }

    private static func eventLaneValue(from candidate: [String: RawJSONValue]) -> RawJSONValue? {
        if let direct = candidate["lane"]
            ?? candidate["label"]
            ?? candidate["sourceLabel"]
            ?? candidate["source_label"]
            ?? candidate["instrument"]
            ?? candidate["class"]
            ?? candidate["type"]
            ?? candidate["name"] {
            return flattenLabelValue(direct)
        }

        for nestedKey in ["instrument", "class", "lane", "source", "drum"] {
            if let nested = candidate[nestedKey]?.dictionary {
                if let label = nested["label"] ?? nested["name"] ?? nested["id"] ?? nested["family"] ?? nested["instrument"] {
                    return flattenLabelValue(label)
                }
            }
        }
        return nil
    }

    private static func flattenLabelValue(_ value: RawJSONValue) -> RawJSONValue? {
        if rawString(value) != nil {
            return value
        }
        guard let object = value.dictionary else { return nil }
        return object["label"] ?? object["name"] ?? object["id"] ?? object["family"] ?? object["instrument"]
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

    private static func normalizeLoopDownbeats(_ downbeatStarts: [Double], tempoBPM: Double?, timeSignature: TimeSignature) -> [Double] {
        let normalized = normalizeStarts(downbeatStarts)
        guard let first = normalized.first,
              first > 0,
              shouldSnapLeadingLoopOffset(firstDownbeatOffset: first, downbeatStarts: normalized, tempoBPM: tempoBPM, timeSignature: timeSignature) else {
            return normalized
        }
        return normalizeStarts(normalized.map { max($0 - first, 0) })
    }

    private static func normalizeLoopBeatStarts(_ beatStarts: [Double], downbeatStarts: [Double], tempoBPM: Double?, timeSignature: TimeSignature) -> [Double] {
        let normalizedBeats = normalizeStarts(beatStarts)
        guard !normalizedBeats.isEmpty else { return [] }

        let firstBeat = normalizedBeats.first ?? 0
        let snappedBeats: [Double]
        if firstBeat > 0,
           shouldSnapLeadingLoopOffset(firstDownbeatOffset: firstBeat, downbeatStarts: downbeatStarts, tempoBPM: tempoBPM, timeSignature: timeSignature) {
            snappedBeats = normalizeStarts(normalizedBeats.map { max($0 - firstBeat, 0) })
        } else {
            snappedBeats = normalizedBeats
        }

        guard downbeatStarts.count >= 2 else { return snappedBeats }

        var repaired: [Double] = []
        let tolerance = 0.0005
        for (index, start) in downbeatStarts.enumerated() {
            let end = index + 1 < downbeatStarts.count ? downbeatStarts[index + 1] : nil
            guard let end, end > start + tolerance else {
                repaired.append(contentsOf: snappedBeats.filter { $0 >= start - tolerance })
                break
            }

            let barBeats = snappedBeats.filter { $0 >= start - tolerance && $0 < end - tolerance }
            if barBeats.count == timeSignature.numerator {
                repaired.append(contentsOf: barBeats)
                continue
            }

            let beatDuration = (end - start) / Double(timeSignature.numerator)
            guard beatDuration > 0.0001 else {
                repaired.append(contentsOf: barBeats)
                continue
            }

            let synthesized = (0..<timeSignature.numerator).map { start + Double($0) * beatDuration }
            repaired.append(contentsOf: synthesized)
        }

        return normalizeStarts(repaired)
    }

    private static func shouldSnapLeadingLoopOffset(firstDownbeatOffset: Double, downbeatStarts: [Double], tempoBPM: Double?, timeSignature: TimeSignature) -> Bool {
        guard firstDownbeatOffset > 0, firstDownbeatOffset <= 0.03 else { return false }
        let completeBarDurations = zip(downbeatStarts, downbeatStarts.dropFirst()).map { $1 - $0 }.filter { $0 > 0.0001 }
        let referenceBeatDurationFromTempo = tempoBPM.map { 60.0 / max($0, 1) }
        let referenceBeatDurationFromBars = completeBarDurations.isEmpty
            ? nil
            : (completeBarDurations.reduce(0, +) / Double(completeBarDurations.count)) / Double(timeSignature.numerator)
        guard let referenceBeatDuration = referenceBeatDurationFromBars ?? referenceBeatDurationFromTempo,
              referenceBeatDuration > 0 else {
            return false
        }
        let maxAllowedOffset = min(referenceBeatDuration * 0.08, 0.03)
        return firstDownbeatOffset <= maxAllowedOffset
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
        if let midiLane = mapMIDINoteLane(rawValue) {
            return midiLane
        }
        guard let raw = normalizedLaneLabel(rawValue) else { return nil }
        switch raw {
        case "kick", "bd", "bass_drum", "bassdrum", "bass_drum_1", "bass_drum_2", "bassdrum_1", "bassdrum_2", "kik", "kick_drum": return .kick
        case "snare", "sd", "sn", "rimshot", "rim", "cross_stick", "side_stick", "sidestick": return .snare
        case "hihat_closed", "closed_hihat", "closed_hat", "closed_hi_hat", "hhc", "hat_closed", "hi_hat_closed", "chh", "hh", "hihat": return .hihatClosed
        case "hihat_open", "open_hihat", "open_hat", "open_hi_hat", "hho", "hat_open", "hi_hat_open", "ohh": return .hihatOpen
        case "tom_low", "low_tom", "floor_tom", "floortom", "floor_tom_low", "low_floor_tom", "high_floor_tom", "tom_3", "floor_tom_1": return .tomLow
        case "tom_mid", "mid_tom", "middle_tom", "mid_tom_1", "mid_tom_2", "tom_medium", "tom_2", "center_tom", "middle_rack_tom": return .tomMid
        case "tom_high", "high_tom", "rack_tom", "racktom", "rack_tom_1", "rack_tom_2", "high_rack_tom", "tom_1": return .tomHigh
        case "crash", "crash_cymbal", "crash_left", "crash_right", "crash_1", "crash_2", "china": return .crash
        case "ride", "ride_cymbal", "ride_bell", "ride_1", "ride_2": return .ride
        case "clap", "handclap", "hand_clap": return .clap
        case "percussion", "perc", "cowbell", "shaker", "tambourine": return .percussion
        default: return nil
        }
    }

    private static func mapMIDINoteLane(_ rawValue: RawJSONValue?) -> DrumLane? {
        guard let note = rawInt(rawValue) else { return nil }
        switch note {
        case 35, 36: return .kick
        case 37, 38, 40: return .snare
        case 42, 44: return .hihatClosed
        case 46: return .hihatOpen
        case 41, 43: return .tomLow
        case 45: return .tomMid
        case 47, 48, 50: return .tomHigh
        case 49, 52, 55, 57: return .crash
        case 51, 53, 59: return .ride
        case 39: return .clap
        case 54, 56, 58, 60, 82, 83: return .percussion
        default: return nil
        }
    }

    private static func normalizedLaneLabel(_ rawValue: RawJSONValue?) -> String? {
        guard let raw = rawString(rawValue)?.lowercased() else { return nil }
        let replaced = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let collapsed = String(replaced)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? nil : collapsed
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
