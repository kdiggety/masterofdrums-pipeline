# MasterOfDrums Pipeline

Standalone, headless pipeline service for MasterOfDrums background processing.

## MVP Direction

This repository is being built as a **CLI + worker + SQLite** application first.

For MVP, the priorities are:

1. durable database-backed workflow state
2. job orchestration and retries
3. chart ingestion and normalization
4. a command-line operational surface

Not in the immediate MVP:

- web server
- admin UI
- auth layer for remote callers

Those can be added later on top of the same domain/application/database core.

## Why This Exists

The pipeline is intended to become the system of record for background processing and workflow state.

It must run independently from:

- the macOS gameplay/admin app
- future admin UI surfaces
- macros or trigger layers

Those systems should eventually act as clients of the pipeline, not host its core logic.

## Runtime Shape

This project should become a headless Swift executable that supports commands like:

- `masterofdrums-pipeline init-db`
- `masterofdrums-pipeline worker`
- `masterofdrums-pipeline enqueue-audio-ingest --source-uri ...`
- `masterofdrums-pipeline list-jobs`
- `masterofdrums-pipeline show-job <job-id>`

## Recommended Stack

- Swift 5.9+
- Swift Package Manager
- SQLite from day one
- async/await for workflow and worker coordination
- structured logging

## Modules

- `PipelineDomain` — core models and workflow state
- `PipelineApplication` — use cases and repository contracts
- `PipelineInfrastructure` — SQLite, migrations, persistence, logging
- `PipelineRuntime` — CLI commands, worker runtime, startup orchestration
- `PipelineService` — executable entry point

## Project Layout

```text
Sources/
  PipelineDomain/
  PipelineApplication/
  PipelineInfrastructure/
  PipelineRuntime/
  PipelineService/
Docs/
  architecture/
  database/
  interfaces/
Config/
  pipeline.example.env
```

## Database-First MVP

The MVP should use a real SQLite database immediately.

Primary state expected in the database:

- jobs
- workflows
- workflow events
- artifacts / source references
- idempotency keys
- schema migrations

Large files should not be stored in SQLite unless there is a specific reason. Prefer storing file/object references plus metadata.

## Final Chart Output

The user-facing deliverable is the **final chart file**.
It is intentionally separate from the run/debug artifact tree.

Default location:

- `./charts/`

Default filename shape:

- `<audio-name>--<timestamp>--<workflow>.modchart.json`

Examples:

- `charts/Lecrazy--2026-04-08T10-25-37--f5fdae.modchart.json`
- `charts/My-Song--2026-04-08T17-40-03--464fbe.modchart.json`

Rules:

- the filename mirrors the source audio basename
- a timestamp is included for sorting and collision resistance
- a short workflow identifier is included for uniqueness/provenance
- final charts are **not** nested under `runs/<run-id>/...`

Override the destination entirely with:

- `PIPELINE_FINAL_CHART_DIR=/some/other/path`

When chart generation succeeds, the worker/CLI prints the exact path explicitly:

- `[pipeline] final chart file: /full/path/to/charts/<audio-name>--<timestamp>--<workflow>.modchart.json`

Operational guidance:

- **Use the printed final chart path when importing into the app**
- Treat `runs/` and the artifact directories as debugging/provenance internals
- `normalized-analysis` and other intermediate JSON outputs are not the app-facing chart deliverable

In short:

- `charts/` = user-facing deliverables
- `runs/` = internal workflow/debugging

## CLI-First MVP

The command line is the first operational surface.

Example commands:

1. `init-db`
   - create database file if missing
   - apply schema migrations

2. `worker`
   - poll queued jobs
   - claim and execute work
   - update durable status and retry metadata

3. `enqueue-audio-ingest`
   - insert a workflow
   - insert the initial job

4. `list-jobs`
   - inspect queued/running/failed work

5. `show-job`
   - inspect one job in detail

## Future Interfaces

A web/API layer may be added later for:

- admin UI
- macro triggers
- external integrations

But that is intentionally deferred until the database and worker core are solid.

## Current Status

Implemented so far:

- initial standalone repo scaffold
- domain/application/runtime structure
- SQLite schema definition and DB-first docs
- CLI-oriented runtime direction
- analyzer runtime integration with timeout/stdout-fallback controls, a direct `validate-audio-analyzer` smoke-test command, a concrete wrapper example (`scripts/analyzer-wrapper.py`), and a repo-local heuristic backend scaffold (`scripts/backend-analyzer.py`) that emits beats/downbeats/segments/drum-event candidates without external ML dependencies

Still to implement:

- concrete chart-generation analyzer wrappers behind the configured analyzer command
- richer analyzer outputs that include beat/downbeat arrays and lane-level drum-event candidates
- analyzer-driven chart shaping now applies beat-aware density controls so prototype charts keep one kick/snare backbone lane per beat, allow clearly stronger analyzer confidence to override the usual beat-position kick/snare bias, preserve downbeat crash accents, and retain open-hat accents alongside a single closed-hat pulse instead of flattening everything into unreadable kick+snare+hat piles
- downstream chart validation/export built on the normalized chart-generation artifacts
- broader fixture/integration coverage beyond the single known WAV path (the corpus/reporting shape now includes real-clip review metadata, linting, and regression summaries, but only one actual WAV fixture is checked in)
- a dedicated CLI surface now exists for corpus evaluation/report export via `evaluate-chart-corpus`, with focused kick/snare/hi-hat distribution checks and review-friendly text/JSON output

Recent spike work for tasks 5/6:

- `scripts/madmom-fallback-backend.py` makes the fallback path concrete enough to validate madmom-style beat/downbeat outputs without committing to a fragile production install yet
- `scripts/adtof-output-adapter.py` and MIDI-aware lane normalization show the current runtime can already consume ADTOF-like drum-event outputs as a stage-2 event source
- `scripts/hybrid-drum-events-backend.py` adds the next seam: keep `beat_this` (or another timing backend) as the beat/downbeat backbone, then optionally merge stage-2 drum-event candidates from a second backend/adapter into the same analyzer payload
- sample fixtures for both spikes live under `scripts/fixtures/`

## Current Testable Slice

The repo is now aimed at a first testable CLI + SQLite slice:

1. `init-db`
2. `enqueue-audio-ingest`
3. `worker`
4. `list-jobs`
5. `list-events` / `list-artifacts`

Example flow:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

export PIPELINE_AUDIO_ANALYZER_COMMAND="./.venv/bin/python ./scripts/analyzer-wrapper.py --input {input} --output {output}"

# legacy single-backend mode
# export PIPELINE_ANALYZER_BACKEND_COMMAND="./.venv/bin/python ./scripts/backend-analyzer.py --input {input} --output {output}"

# preferred rollout mode: new real backend + safety fallback
export PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND="./.venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"
export PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND="./.venv/bin/python ./scripts/backend-analyzer.py --input {input} --output {output}"
export PIPELINE_ANALYZER_FALLBACK_POLICY=on-error-or-invalid
export PIPELINE_ANALYZER_VALIDATION_MODE=require-timing

# optional later-path seam: keep beat/downbeat timing from one backend,
# then merge stage-2 drum-event candidates from another backend/adapter.
# ADTOF is the preferred next stage-2 backend for lane/event candidates.
# export PIPELINE_AUDIO_ANALYZER_COMMAND="./.venv/bin/python ./scripts/hybrid-drum-events-backend.py --input {input} --output {output}"
# export PIPELINE_ANALYZER_TIMING_BACKEND_COMMAND="./.venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"
# export PIPELINE_ANALYZER_EVENT_BACKEND_COMMAND="./.venv/bin/python ./scripts/adtof-stage2-backend.py --input {input} --output {output} --input-json ./scripts/fixtures/adtof-sample-events.json"
# export PIPELINE_ADTOF_BACKEND_COMMAND="python3 /opt/adtof/infer.py --input {input} --output {output}"
# export PIPELINE_ANALYZER_EVENT_POLICY=optional

# optional madmom-style fallback spike instead of the heuristic backend
# export PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND="./.venv/bin/python ./scripts/madmom-fallback-backend.py --input {input} --output {output} --beats-file ./scripts/fixtures/madmom-sample.beats.txt --downbeats-file ./scripts/fixtures/madmom-sample.beats.txt"

export PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=300
export PIPELINE_AUDIO_ANALYZER_STDOUT_JSON=false

# quick preflight + validation loop before touching the job queue
swift run MasterOfDrumsPipeline doctor-audio-analyzer
swift run MasterOfDrumsPipeline validate-audio-analyzer --source-uri file:///tmp/test.wav --source-type file --requested-by cli
python3 ./scripts/test-analyzer-wrapper.py
python3 ./scripts/test-adtof-stage2-backend.py
python3 ./scripts/test-compare-timing-paths.py
python3 ./scripts/test-chart-summary.py

# inspect a generated chart artifact without hand-scanning the full JSON
python3 ./scripts/chart-summary.py /path/to/chart.modchart.json

# compare the same source through primary-only vs forced-fallback timing paths
python3 ./scripts/compare-timing-paths.py --input /tmp/test.wav --output-dir ./tmp/compare-test

# validate-audio-analyzer still prints the full normalized JSON to stdout,
# but now also emits a short operator summary to stderr, e.g.:
# [pipeline] analyzer summary: duration=123.45s | tempo≈120 bpm | segments=42 | tracks=1 | confidence=0.81 | timing=beat_this via fallback, selected=fallback, fallback=validation: payload did not contain recognizable beat/downbeat/subdivision timing

swift run MasterOfDrumsPipeline init-db
swift run MasterOfDrumsPipeline enqueue-audio-ingest --source-uri file:///tmp/test.wav --source-type file --requested-by cli
swift run MasterOfDrumsPipeline worker --stop-after-idle-polls 2
swift run MasterOfDrumsPipeline list-jobs
swift run MasterOfDrumsPipeline list-events --limit 20
swift run MasterOfDrumsPipeline list-artifacts --limit 20
```

`list-artifacts` now appends a compact `summary="..."` field for `audio_analysis` artifacts so operators can spot the selected timing backend / fallback path without opening the JSON artifact by hand.

For repeatable drum-event quality review on known tracks, you can now export generated base-chart JSON files into a directory and run:

```bash
swift run MasterOfDrumsPipeline evaluate-chart-corpus \
  --corpus Tests/PipelineRuntimeTests/Fixtures/chart-eval-corpus.json \
  --charts-dir ./tmp/chart-eval \
  --baseline-charts-dir ./tmp/chart-eval-baseline \
  --tag smoke \
  --output-path ./tmp/chart-eval/report.json \
  --text-output-path ./tmp/chart-eval/report.txt
```

Chart files are discovered recursively from `--charts-dir` using the naming convention `<song-id>--<difficulty>.json` (or `__` as a separator). When `--baseline-charts-dir` is present, matching charts from that directory are compared against the candidate set and the text/JSON report includes compact delta lines for note count, density, focused kick/snare/hat balance, and a small added/removed note-preview surface. Add `--song-id <id>` to isolate one known track during review.

For a lower-level look at analyzer label coverage vs final lane retention, use:

```bash
python3 scripts/audit-analyzer-lane-mapping.py /path/to/audio-analysis.json
python3 scripts/audit-analyzer-lane-mapping.py /path/to/normalized-analysis.json /path/to/base-chart.json
```

That audit helper reports raw labels, mapped lane candidates, unmapped labels, normalized drum-event lane totals, base-chart lane totals, and any embedded `drumEventDiagnostics`. See `Docs/quality/analyzer-lane-mapping-audit.md` for the current audit findings and where kick/snare/hat/tom/crash loss is most likely happening.

For a repeatable operator-facing smoke run that exercises the same CLI surface end to end with a bundled WAV fixture and a deterministic mock analyzer, use:

```bash
scripts/worker-smoke.sh
```

That harness provisions an isolated temp database/artifact root, runs `init-db`, `enqueue-audio-ingest`, `worker`, `list-jobs`, `list-events`, and `list-artifacts`, then asserts that the expected job states, workflow events, and artifact types are present. Add `--keep-workdir` if you want to inspect the generated SQLite DB, artifacts, and per-command logs afterward.

If the repo moves, update the `.env` file or re-export the commands so they point at the venv that lives inside the current checkout. The analyzer command examples above intentionally pin the interpreter to `./.venv/bin/python` instead of relying on whichever `python3` happens to be first on `PATH`.

## Setup Script

A bootstrap script is included at `scripts/setup-pipeline.sh`.

Useful variants:

```bash
# base pipeline/db bootstrap
scripts/setup-pipeline.sh

# also seed analyzer env vars + helper scripts
scripts/setup-pipeline.sh --bootstrap-analyzer

# also create .venv and install requirements.txt into it
scripts/setup-pipeline.sh --bootstrap-analyzer --auto-install-analyzer
```

When `--bootstrap-analyzer` is enabled, setup now also generates:

- `scripts/check-analyzer-env.sh` — checks repo venv, `requirements.txt`, `ffmpeg`/`ffprobe`, and `beat_this` availability
- `scripts/bootstrap-analyzer-venv.sh` — creates the repo-local venv and installs `requirements.txt`
- `scripts/run-validate-analyzer.sh /path/to/test.wav` — runs the Swift analyzer validation command against a real file

That keeps the Mac setup path closer to the repo's checked-in analyzer contract instead of relying on copy/pasted README commands.

For a lightweight regression check around setup/bootstrap itself, run:

```bash
scripts/setup-smoke.sh
```

That harness uses an isolated temp install root plus a stubbed `swift run` so it can verify generated helper scripts, seeded analyzer env defaults, and basic rerun/idempotency behavior without requiring a real release build.

## beat_this Primary Backend Bootstrap

The intended analyzer stack is now:

1. `scripts/analyzer-wrapper.py`
2. `scripts/beat-this-backend.py`
3. `scripts/backend-analyzer.py` as automatic fallback when `beat_this` is unavailable or fails

Minimal Python-side bootstrap for the real primary path:

```bash
python3 -m venv .venv
source .venv/bin/activate
./.venv/bin/python -m pip install --upgrade pip
./.venv/bin/python -m pip install -r requirements.txt
brew install ffmpeg
```

The checked-in [`requirements.txt`](/Users/klewisjr/Development/MacOS/masterofdrums-pipeline/requirements.txt) captures the current repo-local analyzer stack so future Mac worker setup does not depend on copying package names out of the README.

Important setup notes:

- Use the repo-local `.venv` for analyzer installs and validation. On Homebrew-managed Python, installing into the global interpreter can fail with `externally-managed-environment`.
- Prefer `./.venv/bin/python -m pip ...` over a bare `pip ...` so the install target is unambiguous.
- `ffmpeg` is required for MP3/non-WAV local validation and recommended in general.
- The current `beat_this` runtime path expects audio-loading dependencies such as `torch`, `torchcodec`, and `soundfile`; those are included in `requirements.txt`.
- If `pip` cannot download packages from `files.pythonhosted.org`, verify DNS on the active network adapter/service the machine is actually using.

Verify the install before running the pipeline:

```bash
swift run MasterOfDrumsPipeline doctor-audio-analyzer
./.venv/bin/python -c 'import importlib.util, shutil; print("beat_this_py:", bool(importlib.util.find_spec("beat_this"))); print("beat_this_cli:", shutil.which("beat_this"))'
```

Expected result: `beat_this_py: True` or a non-empty `beat_this_cli:` path. If both are missing, the wrapper will fall back to the heuristic backend instead of using `beat_this`.

Important nuance: the current `beat_this` backend provides beat/downbeat timing, not lane-level drum transcription. So a successful mixed-source run can legitimately use `beat_this` for timing while `heuristicDrumEvents` still supplies the chart's drum events. Recent diagnostics and artifact notes call that split out explicitly.

Then set the analyzer env vars in your shell or `.env` file:

```bash
export PIPELINE_AUDIO_ANALYZER_COMMAND="./.venv/bin/python ./scripts/analyzer-wrapper.py --input {input} --output {output}"

# legacy single-backend mode
# export PIPELINE_ANALYZER_BACKEND_COMMAND="./.venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"

# preferred current setup
export PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND="./.venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"
export PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND="./.venv/bin/python ./scripts/backend-analyzer.py --input {input} --output {output}"
export PIPELINE_ANALYZER_FALLBACK_POLICY=on-error-or-invalid
export PIPELINE_ANALYZER_VALIDATION_MODE=require-timing
export PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=300
export PIPELINE_AUDIO_ANALYZER_STDOUT_JSON=false
```

Recommended validation workflow after setting those vars:

```bash
./.venv/bin/python -c 'import importlib.util, shutil; print("beat_this_py:", bool(importlib.util.find_spec("beat_this"))); print("beat_this_cli:", shutil.which("beat_this"))'
swift run MasterOfDrumsPipeline validate-audio-analyzer --source-uri file:///tmp/test.wav --source-type file --requested-by cli --output-path /tmp/audio-analysis.json
python3 ./scripts/test-analyzer-wrapper.py
python3 ./scripts/compare-timing-paths.py --input /tmp/test.wav --output-dir ./tmp/compare-test
```

`validate-audio-analyzer` still prints the full persisted artifact JSON to stdout. When `--output-path` is used, it now also writes two wrapper-friendly sidecars next to the artifact:

- `/tmp/audio-analysis.summary.json` — compact machine-readable validation summary
- `/tmp/audio-analysis.summary.txt` — operator-facing text summary with backend/fallback/warning details

That keeps the existing wrapper contract intact while giving launchers/GUI glue an easier surface to inspect than the full artifact payload.

That sequence catches the current failure modes quickly:

1. missing `beat_this` / Python deps inside the repo venv
2. stale analyzer command strings after moving the repo to a new path
3. wrapper/backend payloads that fail `require-timing` validation
4. obvious contract-shape regressions before running the full worker loop

Example usage:

```bash
# local / all-in-one setup
scripts/setup-pipeline.sh

# pipeline host with DB/artifacts on a mounted remote volume
scripts/setup-pipeline.sh \
  --database-path /Volumes/mod-pipeline-db/masterofdrums-pipeline.sqlite \
  --artifact-root /Volumes/mod-pipeline-db/artifacts
```

Important: the current MVP still uses SQLite. If you place the database on a separate machine,
that machine must expose storage to the pipeline host with SQLite-compatible file locking.
Treat that as a transitional deployment shape until the pipeline moves to a network database.

Note: this assumes Swift and SQLite development libraries are available on the machine.
For the primary analyzer path, also install Python 3 plus `beat_this` and its PyTorch/audio dependencies; the backend will otherwise fall back to the repo-local heuristic analyzer.

See `Docs/architecture/standalone-pipeline-plan.md`, `Docs/database/sqlite-schema.md`, `Docs/interfaces/cli-interface-outline.md`, `Docs/interfaces/audio-analysis-contract.md`, `Docs/interfaces/chart-generation-analyzer-stack.md`, `Docs/interfaces/chart-generation-contract.md`, `Docs/interfaces/madmom-fallback-spike.md`, `Docs/research/adtof-feasibility.md`, and `Docs/quality/chart-quality-evaluation.md` for the current corpus/reporting scaffolding and the gap to a real CLI-driven evaluation loop.
