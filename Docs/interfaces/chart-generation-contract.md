# Chart Generation Contracts

This document defines the next-level contracts that should sit between `audio_analysis` and eventual gameplay/export chart formats.

## Why this layer exists

The current repository has an MVP `audio_analysis` contract that captures coarse analysis summary plus broad segments. That is useful for provenance, but it is not yet specific enough to drive deterministic chart generation.

Chart generation needs a stable, gameplay-oriented handoff with:

- a normalized beat grid
- drum events mapped into gameplay lanes
- a base chart representation that is still editor/UI agnostic

That suggests a two-artifact progression after `audio_analysis`:

1. `normalized_analysis` — timing + detector events normalized for charting
2. `base_chart` — quantized gameplay note data suitable for validation/export

## Proposed workflow shape

```text
audio_ingest
  -> audio_analyze
  -> chart_generate (emits normalized_analysis and base_chart)
  -> chart_validate
  -> chart_export
```

This keeps the pipeline free to re-run chart generation from the persisted normalized timing/event artifact without requiring raw analysis to be repeated.

## Artifact conventions

### `normalized_analysis`

- `artifact_type`: `normalized_analysis`
- `content_type`: `application/json`
- schema: `Resources/schemas/normalized-analysis-result.schema.json`
- purpose: stable timing/event handoff for chart generation logic

### `base_chart`

- `artifact_type`: `base_chart`
- `content_type`: `application/json`
- schema: `Resources/schemas/base-chart.schema.json`
- purpose: gameplay-oriented chart contract before validator/export-specific transforms

## Normalized analysis contract

The normalized analysis artifact should resolve raw detector output into a chart-friendly representation.

### Top-level fields

- `schemaVersion`
- `schemaURI`
- `analysisStage` — `chart_generation_ready_v1`
- `status`
- `source`
- `summary`
- `beatGrid`
- `drumEvents`
- `warnings`
- `note`

### `source`

Extends the source provenance from `audio_analysis` and explicitly points back to the upstream artifact:

- `sourceType`
- `sourceURI`
- `requestedBy`
- `audioAnalysisArtifactURI`

### `summary`

The summary is a compact index for list views and quick checks:

- `normalizedAt`
- `durationSeconds`
- `estimatedTempoBPM`
- `downbeatOffsetSeconds`
- `beatCount`
- `barCount`
- `drumEventCount`
- `predominantTimeSignature`
- `confidence`

### `beatGrid`

`beatGrid` is the authoritative timing map for downstream chart generation.

Each row represents a beat or subdivision anchor with:

- `beatIndex` — absolute beat counter from song start
- `barIndex` — zero-based measure index
- `beatInBar` — one-based beat position within the measure
- `subdivisionIndex` — absolute subdivision counter
- `subdivisionInBeat` — zero-based slot inside the beat
- `startSeconds`
- `durationSeconds`
- `isDownbeat`
- `tempoBPM` — local tempo at that anchor when tempo maps vary
- `timeSignature` — optional override if meter changes mid-song
- `confidence`

Design choice: keep both beat- and subdivision-level indexing. Beat-level indexing is convenient for measure construction; subdivision indexing makes quantization and note placement deterministic.

### `drumEvents`

`drumEvents` captures detector output mapped into MasterOfDrums gameplay lanes.

Each event contains:

- `eventID`
- `onsetSeconds`
- `onsetBeatIndex`
- `onsetSubdivisionIndex`
- `lane`
- `velocity`
- `sourceLabel` — original detector class if different from lane name
- `confidence`

### Lane set

The proposed stable lane enum is:

- `kick`
- `snare`
- `hihat_closed`
- `hihat_open`
- `tom_low`
- `tom_mid`
- `tom_high`
- `crash`
- `ride`
- `clap`
- `percussion`

Opinionated call: include `clap` and a catch-all `percussion` lane now, even if gameplay later collapses them. It is easier to merge lanes downstream than to recover lost distinctions later.

## Base chart contract

The base chart is the first chart-shaped artifact intended for deterministic validation/export. It should remain neutral about editor concerns, UI state, or app-specific rendering metadata.

### Top-level fields

- `schemaVersion`
- `schemaURI`
- `chartStage` — `base_chart_v1`
- `status`
- `source`
- `chart`
- `warnings`
- `note`

### `source`

- `normalizedAnalysisArtifactURI`
- `sourceType`
- `sourceURI`
- `requestedBy`

### `chart`

- `generatedAt`
- `ticksPerBeat` — default proposed value: `480`
- `offsetSeconds`
- `lanes`
- `difficulty`
- `measures`
- `notes`

### `measures`

Measures encode meter structure independent of individual note placement:

- `barIndex`
- `startBeatIndex`
- `beatCount`
- `timeSignature`

### `notes`

Each gameplay note should include:

- `noteID`
- `lane`
- `tick`
- `beatIndex`
- `subdivisionIndex`
- `startSeconds`
- `durationTicks`
- `velocity`
- `sourceEventID`

Design choice: keep both musical time (`tick`, `beatIndex`, `subdivisionIndex`) and wall-clock time (`startSeconds`). This avoids repeated re-derivation and makes debugging generation drift much easier.

## Relationship to current `audio_analysis`

The current `audio_analysis` artifact is still useful as the detector/provenance record, but it is too loose for charting because:

- `segments` are broad regions, not beat-accurate timing anchors
- there is no stable event-level drum lane mapping
- chart generation would otherwise need to infer quantization strategy ad hoc

So the intended handoff is:

```text
audio_analysis -> normalized_analysis -> base_chart
```

not direct `audio_analysis -> base_chart`.

## Expected metadata summaries

For quick artifact listing/querying, `metadata_json` should stay compact.

Suggested summary for `normalized_analysis`:

- `durationSeconds`
- `estimatedTempoBPM`
- `beatCount`
- `barCount`
- `drumEventCount`
- `confidence`

Suggested summary for `base_chart`:

- `difficulty`
- `ticksPerBeat`
- `measureCount`
- `noteCount`
- `laneCount`

## Current repo changes aligned to this proposal

This proposal is backed by:

- `Sources/PipelineDomain/ChartContracts.swift`
- `Resources/schemas/normalized-analysis-result.schema.json`
- `Resources/schemas/base-chart.schema.json`
- `Sources/PipelineRuntime/PipelineRuntime.swift`

The runtime now produces `normalized_analysis` and `base_chart` artifacts during `chart_generate`.
For the current slice, it prefers richer analyzer output when present (beat arrays, optional subdivision/tatum anchors, and drum-event candidates inside `rawAnalyzerOutput`) and otherwise falls back to a deterministic tempo-derived beat grid so downstream validation/export can start against stable artifacts now.

## Recommended next implementation step

The current runtime now produces `normalized_analysis` and `base_chart` during `chart_generate`.

The next refinement step should be to improve the quality of those artifacts by:

1. replacing fallback tempo-derived beat grids with richer analyzer-provided beat/downbeat arrays whenever available
2. improving drum-event normalization and lane mapping from analyzer output
3. tightening quantization from coarse beat anchoring to subdivision-aware placement
4. collapsing duplicate analyzer hits that quantize into the same gameplay lane/slot so the chart reflects intent instead of raw detector spam
5. feeding generated `base_chart` artifacts into the chart-quality evaluation loop
6. preparing `chart_validate` to consume the persisted `base_chart` artifact directly

That keeps `chart_validate` deterministic while moving chart generation from heuristic scaffolding toward analyzer-driven output.
