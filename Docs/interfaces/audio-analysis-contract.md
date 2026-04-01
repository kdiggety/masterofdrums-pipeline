# Audio Analysis Contract

This document defines the persisted artifact contract for the `audio_analyze` stage.

## Current runtime behavior

The worker now expects a real analyzer command via:

- `PIPELINE_AUDIO_ANALYZER_COMMAND`

The command is a shell template and must include:

- `{input}` — source audio file path
- `{output}` — destination JSON path under `PIPELINE_ARTIFACT_ROOT`

Example:

```bash
PIPELINE_AUDIO_ANALYZER_COMMAND="python3 /opt/mod/analyzer.py --input {input} --output {output}"
```

The worker will:

1. claim an `audio_analyze` job
2. create an output path under `PIPELINE_ARTIFACT_ROOT/audio-analysis/<workflow-id>/`
3. run the analyzer command
4. require a JSON file at `{output}`
5. normalize that JSON into the pipeline contract if the analyzer emits a looser shape
6. persist an `artifacts` row pointing at the JSON file URI

## Artifact conventions

- `artifact_type`: `audio_analysis`
- `content_type`: `application/json`
- `uri`: file URI of the persisted JSON artifact on disk
- `metadata_json`: compact summary JSON for quick listing/querying (`analysis` only, not the full contract)

## Contract shape

Top-level persisted JSON includes:

- `schemaVersion`
- `schemaURI`
- `analysisStage` — currently `audio_analysis_mvp`
- `status`
- `source`
- `analysis`
- `segments`
- `warnings`
- `note`
- `rawAnalyzerOutput` — optional copy of the analyzer's original JSON when normalization was needed

`analysis` currently carries the stable handoff summary:

- `analyzedAt`
- `durationSeconds`
- `audioTrackCount`
- `estimatedSegmentCount`
- `estimatedTempoBPM`
- `downbeatOffsetSeconds`
- `confidence`
- `artifactURI`
- `analyzerCommand`

## Expectations for analyzer implementations

Preferred: emit the full pipeline contract directly.

Accepted: emit a simpler JSON object with fields like:

- `analysis.durationSeconds`
- `analysis.audioTrackCount`
- `analysis.estimatedSegmentCount`
- `analysis.estimatedTempoBPM`
- `analysis.downbeatOffsetSeconds`
- `analysis.confidence`
- `segments[]`
- `warnings[]`
- `note`

The worker will wrap that output into the stable contract.

## Known risks

- Analyzer invocation currently uses `/bin/bash -lc`, so quoting and command safety depend on the configured template.
- The worker assumes file-based artifact persistence, not object storage.
- Downstream consumers should read the artifact at `uri`; `metadata_json` is only a summary.
