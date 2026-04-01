# Audio Analysis Contract

This document defines the persisted artifact contract for the `audio_analyze` stage.

## Current runtime behavior

The worker now expects a real analyzer command via:

- `PIPELINE_AUDIO_ANALYZER_COMMAND`
- `PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS` (optional)
- `PIPELINE_AUDIO_ANALYZER_STDOUT_JSON` (optional)

The command is a shell template and must include:

- `{input}` — source audio file path
- `{output}` — destination JSON path under `PIPELINE_ARTIFACT_ROOT`

Example:

```bash
PIPELINE_AUDIO_ANALYZER_COMMAND="python3 ./scripts/analyzer-wrapper.py --input {input} --output {output}"
PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=300
PIPELINE_AUDIO_ANALYZER_STDOUT_JSON=false
```

The worker will:

1. claim an `audio_analyze` job
2. create an output path under `PIPELINE_ARTIFACT_ROOT/audio-analysis/<workflow-id>/`
3. run the analyzer command
4. wait for the analyzer to exit successfully (or fail on timeout/non-zero exit)
5. read JSON from `{output}`; if stdout fallback is enabled and no file was written, accept JSON from stdout instead
6. normalize that JSON into the pipeline contract if the analyzer emits a looser shape
7. persist an `artifacts` row pointing at the JSON file URI

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

The runtime injects these environment variables into the analyzer process so wrappers can log or include pipeline context without extra argument churn:

- `PIPELINE_ANALYZER_INPUT_PATH`
- `PIPELINE_ANALYZER_OUTPUT_PATH`
- `PIPELINE_ANALYZER_WORKFLOW_ID`
- `PIPELINE_ANALYZER_JOB_ID`
- `PIPELINE_ANALYZER_SOURCE_URI`
- `PIPELINE_ANALYZER_REQUESTED_BY`

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

For chart-generation normalization, looser wrapper outputs are also accepted when they contain recognizable timing/event payloads, for example:

- beat arrays at `beats`, `beatTimes`, `beat_times`, or nested under `timing.*`
- downbeat arrays at `downbeats`, `downbeatTimes`, `downbeat_times`, or nested under `timing.*`
- drum-event arrays at `drumEvents`, `drum_events`, `events`, `hits`, `notes`, or nested under `drums.*` / `percussion.*`
- wrapper containers like `result`, `output`, `payload`, or `data`

The worker will wrap that output into the stable contract, and downstream chart generation will attempt to normalize those common variants before falling back to heuristic timing/events.

## Known risks

- Analyzer invocation currently uses `/bin/bash -lc`, so quoting and command safety depend on the configured template.
- Timeout enforcement currently terminates the shell process; wrappers that spawn detached children should clean those up explicitly.
- Stdout fallback is useful for simple wrappers/tests, but file output remains the preferred production path.
- The worker assumes file-based artifact persistence, not object storage.
- Downstream consumers should read the artifact at `uri`; `metadata_json` is only a summary.
