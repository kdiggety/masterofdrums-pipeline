# Audio Analysis Contract

This document defines the persisted artifact contract for the `audio_analyze` stage.

## Current runtime behavior

The worker now expects a real analyzer command via:

- `PIPELINE_AUDIO_ANALYZER_COMMAND`
- `PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS` (optional)
- `PIPELINE_AUDIO_ANALYZER_STDOUT_JSON` (optional)

When `PIPELINE_AUDIO_ANALYZER_COMMAND` points at `scripts/analyzer-wrapper.py`, the wrapper can also read these inherited env vars for primary/fallback backend orchestration:

- `PIPELINE_ANALYZER_BACKEND_COMMAND` — legacy single backend passthrough
- `PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND` — preferred primary backend for a new real analyzer path
- `PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND` — fallback backend (heuristic backend or madmom spike)
- `PIPELINE_ANALYZER_FALLBACK_POLICY` — `disabled`, `on-error`, `on-invalid`, `on-error-or-invalid`, or `always`
- `PIPELINE_ANALYZER_VALIDATION_MODE` — `none` or `require-timing`

The command is a shell template and must include:

- `{input}` — source audio file path
- `{output}` — destination JSON path under `PIPELINE_ARTIFACT_ROOT`

Example:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip

PIPELINE_AUDIO_ANALYZER_COMMAND="./.venv/bin/python ./scripts/analyzer-wrapper.py --input {input} --output {output}"

# simplest legacy mode: one backend behind the stable wrapper entry point
# PIPELINE_ANALYZER_BACKEND_COMMAND="./.venv/bin/python ./scripts/backend-analyzer.py --input {input} --output {output}"

# preferred rollout mode for the current real backend:
PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND="./.venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"
PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND="./.venv/bin/python ./scripts/backend-analyzer.py --input {input} --output {output}"
PIPELINE_ANALYZER_FALLBACK_POLICY=on-error-or-invalid
PIPELINE_ANALYZER_VALIDATION_MODE=require-timing

# optional alternate fallback spike:
# PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND="./.venv/bin/python ./scripts/madmom-fallback-backend.py --input {input} --output {output} --beats-file ./scripts/fixtures/madmom-sample.beats.txt --downbeats-file ./scripts/fixtures/madmom-sample.beats.txt"

PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=300
PIPELINE_AUDIO_ANALYZER_STDOUT_JSON=false
```

The repo-local venv path is intentional here. It keeps analyzer execution pinned to the Python environment that actually has `beat_this` and related deps installed, which avoids the path drift that happens after moving the checkout to a new machine or directory.

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

The runtime injects these environment variables into the analyzer process so wrappers can log or include pipeline context without extra argument churn. Because the worker inherits the parent environment, wrapper-specific variables such as `PIPELINE_ANALYZER_BACKEND_COMMAND`, `PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND`, and `PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND` can be used to keep the top-level analyzer command stable while swapping real backend implementations.

The runtime injects these environment variables into the analyzer process:

- `PIPELINE_ANALYZER_INPUT_PATH`
- `PIPELINE_ANALYZER_OUTPUT_PATH`
- `PIPELINE_ANALYZER_WORKFLOW_ID`
- `PIPELINE_ANALYZER_JOB_ID`
- `PIPELINE_ANALYZER_SOURCE_TYPE`
- `PIPELINE_ANALYZER_SOURCE_URI`
- `PIPELINE_ANALYZER_REQUESTED_BY`
- `PIPELINE_ANALYZER_CONTRACT_SCHEMA_URI`
- `PIPELINE_ANALYZER_CONTRACT_SCHEMA_VERSION`

The current wrapper/backend setup also commonly relies on these inherited operator-facing env vars:

- `PIPELINE_AUDIO_ANALYZER_COMMAND`
- `PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS`
- `PIPELINE_AUDIO_ANALYZER_STDOUT_JSON`
- `PIPELINE_ANALYZER_BACKEND_COMMAND` (legacy single-backend mode)
- `PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND`
- `PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND`
- `PIPELINE_ANALYZER_FALLBACK_POLICY`
- `PIPELINE_ANALYZER_VALIDATION_MODE`
- `PIPELINE_BEAT_THIS_MODEL`
- `PIPELINE_BEAT_THIS_DEVICE`
- `PIPELINE_BEAT_THIS_DBN`
- `PIPELINE_BEAT_THIS_FLOAT16`
- `PIPELINE_ANALYZER_TIMING_BACKEND_COMMAND`
- `PIPELINE_ANALYZER_EVENT_BACKEND_COMMAND`
- `PIPELINE_ANALYZER_EVENT_POLICY`

Preferred: emit the full pipeline contract directly.

The repo now ships `scripts/beat-this-backend.py` as the intended primary backend. It tries the `beat_this` Python API first, then the `beat_this` CLI if available, and finally falls back to `scripts/backend-analyzer.py` unless fallback is disabled. That keeps the wrapper/backend seam stable while making the default path genuinely model-backed when dependencies are installed.

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
- subdivision/tatum arrays at `subdivisions`, `subdivisionTimes`, `subdivision_times`, `tatums`, `tatumTimes`, `tatum_times`, or nested under `timing.*`
- timing entries as raw seconds or objects like `{ "time": { "seconds": ... } }`, `{ "start": { "seconds": ... } }`, `{ "position": { "seconds": ... } }`, `{ "offset": { "seconds": ... } }`
- drum-event arrays at `drumEvents`, `drum_events`, `drumEventCandidates`, `events`, `hits`, `notes`, `candidates`, `predictions`, `detections`, nested under `drums.*` / `percussion.*` / `transcription.*`, or wrapped inside `tracks[]` / `instruments[]`
- event labels expressed directly or as small objects like `{ "instrument": { "label": "snare" } }`, `{ "lane": { "name": "closed hat" } }`, or nested event wrappers like `{ "event": { ... } }`
- wrapper containers like `result`, `output`, `payload`, `data`, `response`, or `prediction`

The worker will wrap that output into the stable contract, and downstream chart generation will attempt to normalize those common variants before falling back to heuristic timing/events.

Important current behavior: `scripts/beat-this-backend.py` is a timing backend, not a drum transcription backend. In the common mixed-source path, `beat_this` provides beat/downbeat timing while `heuristicDrumEvents` in chart generation supplies the drum-event scaffold. Diagnostics, warnings, and artifact notes should therefore be read as two independent questions: where timing came from, and where drum events came from.

## Wrapper fallback / validation policy

For the current repo-local wrapper, the practical rollout policy is:

1. keep `PIPELINE_AUDIO_ANALYZER_COMMAND` stable and pointed at `scripts/analyzer-wrapper.py`
2. put the new real backend behind `PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND`
3. keep a known-safe fallback behind `PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND`
4. set `PIPELINE_ANALYZER_FALLBACK_POLICY=on-error-or-invalid`
5. set `PIPELINE_ANALYZER_VALIDATION_MODE=require-timing` so metadata-only payloads do not silently replace beat/downbeat-capable backends

That gives the pipeline a conservative default:

- **primary succeeds with timing output** → keep the primary result
- **primary exits non-zero** → fall back to the heuristic backend or madmom spike
- **primary returns JSON but no recognizable beat/downbeat/subdivision timing** → treat it as invalid for chart timing and fall back
- **operators want to inspect only the fallback path** → set `PIPELINE_ANALYZER_FALLBACK_POLICY=always`
- **operators want legacy behavior** → keep using only `PIPELINE_ANALYZER_BACKEND_COMMAND`

The wrapper records the selected backend, fallback policy, validation mode, and fallback reason under `runtime.*` in the backend payload so validation runs and saved artifacts make backend arbitration visible.

When `scripts/hybrid-drum-events-backend.py` is used directly as the analyzer command, it also records `runtime.timingBackendCommand`, `runtime.eventBackendCommand`, `runtime.eventPolicy`, `runtime.eventBackendUsed`, and `runtime.eventBackendFailure` so merged timing/event experiments stay auditable in saved artifacts.

## Fast validation loop

Before enqueueing full workflows, operators can now run:

```bash
./.venv/bin/python -c 'import importlib.util, shutil; print("beat_this_py:", bool(importlib.util.find_spec("beat_this"))); print("beat_this_cli:", shutil.which("beat_this"))'
swift run MasterOfDrumsPipeline validate-audio-analyzer --source-uri file:///tmp/test.wav --source-type file --requested-by cli --output-path /tmp/audio-analysis.json
python3 ./scripts/test-analyzer-wrapper.py
```

Recommended order:

1. verify the repo-local venv can actually import `beat_this` (or at least expose the CLI)
2. run `validate-audio-analyzer` against a real file path to confirm the configured command template, env vars, and normalization flow
3. run the repo-local wrapper smoke test to catch obvious wrapper/backend contract regressions
4. only then enqueue workflows or run the worker loop

That sequence is meant as the quickest way to verify the current real backend command/template before involving SQLite job orchestration.

## Known risks

- Analyzer invocation currently uses `/bin/bash -lc`, so quoting and command safety depend on the configured template.
- Timeout enforcement currently terminates the shell process; wrappers that spawn detached children should clean those up explicitly.
- Stdout fallback is useful for simple wrappers/tests, but file output remains the preferred production path.
- The worker assumes file-based artifact persistence, not object storage.
- Downstream consumers should read the artifact at `uri`; `metadata_json` is only a summary.
