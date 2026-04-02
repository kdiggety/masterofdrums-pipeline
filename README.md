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
- analyzer-driven chart shaping now applies beat-aware density controls so prototype charts keep one kick/snare backbone lane per beat, allow downbeat crash accents, and thin overlapping hi-hat stacks into pulse/texture instead of unreadable kick+snare+hat piles
- downstream chart validation/export built on the normalized chart-generation artifacts
- broader fixture/integration coverage beyond the single known WAV path (the corpus/reporting shape now includes real-clip review metadata, linting, and regression summaries, but only one actual WAV fixture is checked in)
- a dedicated CLI surface for corpus evaluation/report export; the quality loop exists in tests/domain code with manifest linting and review-friendly text output, but is not yet an operator-facing command

Recent spike work for tasks 5/6:

- `scripts/madmom-fallback-backend.py` makes the fallback path concrete enough to validate madmom-style beat/downbeat outputs without committing to a fragile production install yet
- `scripts/adtof-output-adapter.py` and MIDI-aware lane normalization show the current runtime can already consume ADTOF-like drum-event outputs as a stage-2 event source
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

export PIPELINE_AUDIO_ANALYZER_COMMAND="./.venv/bin/python ./scripts/analyzer-wrapper.py --input {input} --output {output}"

# legacy single-backend mode
# export PIPELINE_ANALYZER_BACKEND_COMMAND="./.venv/bin/python ./scripts/backend-analyzer.py --input {input} --output {output}"

# preferred rollout mode: new real backend + safety fallback
export PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND="./.venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"
export PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND="./.venv/bin/python ./scripts/backend-analyzer.py --input {input} --output {output}"
export PIPELINE_ANALYZER_FALLBACK_POLICY=on-error-or-invalid
export PIPELINE_ANALYZER_VALIDATION_MODE=require-timing

# optional madmom-style fallback spike instead of the heuristic backend
# export PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND="./.venv/bin/python ./scripts/madmom-fallback-backend.py --input {input} --output {output} --beats-file ./scripts/fixtures/madmom-sample.beats.txt --downbeats-file ./scripts/fixtures/madmom-sample.beats.txt"

export PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=300
export PIPELINE_AUDIO_ANALYZER_STDOUT_JSON=false

# quick validation loop before touching the job queue
swift run MasterOfDrumsPipeline validate-audio-analyzer --source-uri file:///tmp/test.wav --source-type file --requested-by cli
python3 ./scripts/test-analyzer-wrapper.py

swift run MasterOfDrumsPipeline init-db
swift run MasterOfDrumsPipeline enqueue-audio-ingest --source-uri file:///tmp/test.wav --source-type file --requested-by cli
swift run MasterOfDrumsPipeline worker --stop-after-idle-polls 2
swift run MasterOfDrumsPipeline list-jobs
swift run MasterOfDrumsPipeline list-events --limit 20
swift run MasterOfDrumsPipeline list-artifacts --limit 20
```

If the repo moves, update the `.env` file or re-export the commands so they point at the venv that lives inside the current checkout. The analyzer command examples above intentionally pin the interpreter to `./.venv/bin/python` instead of relying on whichever `python3` happens to be first on `PATH`.

## Setup Script

A bootstrap script is included at `scripts/setup-pipeline.sh`.

## beat_this Primary Backend Bootstrap

The intended analyzer stack is now:

1. `scripts/analyzer-wrapper.py`
2. `scripts/beat-this-backend.py`
3. `scripts/backend-analyzer.py` as automatic fallback when `beat_this` is unavailable or fails

Minimal Python-side bootstrap for the real primary path:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
# install a PyTorch build that matches your platform from https://pytorch.org/get-started/locally/
python3 -m pip install tqdm einops soxr rotary-embedding-torch
python3 -m pip install https://github.com/CPJKU/beat_this/archive/main.zip
# ffmpeg is recommended for non-WAV input decoding
```

Verify the install before running the pipeline:

```bash
./.venv/bin/python -c 'import importlib.util, shutil; print("beat_this_py:", bool(importlib.util.find_spec("beat_this"))); print("beat_this_cli:", shutil.which("beat_this"))'
```

Expected result: `beat_this_py: True` or a non-empty `beat_this_cli:` path. If both are missing, the wrapper will fall back to the heuristic backend instead of using `beat_this`.

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
```

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
