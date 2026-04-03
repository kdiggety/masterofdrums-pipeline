# Worker Smoke Runbook

This codifies the current manual validation loop into one repeatable harness.

## What it covers

The smoke harness executes the CLI surface in this order:

1. `init-db`
2. `enqueue-audio-ingest`
3. `worker --stop-after-idle-polls 2`
4. `list-jobs`
5. `list-events --limit 20`
6. `list-artifacts --limit 20`

It uses the bundled `known-tone.wav` XCTest fixture and a deterministic mock analyzer payload so the run is stable and does not depend on `beat_this`, PyTorch, or a repo-local venv.

## Quick start

From the repo root:

```bash
scripts/worker-smoke.sh
```

Expected result:

- the script exits `0`
- it prints `[smoke] PASS`
- `list-jobs` includes succeeded `audio_ingest`, `audio_analyze`, and `chart_generate` jobs
- `list-events` includes `job_enqueued`, `audio_analysis_completed`, and `base_chart_created`
- `list-artifacts` includes `source_audio`, `audio_analysis`, `normalized_analysis`, and `base_chart`

## Useful options

```bash
# preserve temp outputs for inspection
scripts/worker-smoke.sh --keep-workdir

# point at a different local file or file:// URI
scripts/worker-smoke.sh --source-uri /absolute/path/to/audio.wav
scripts/worker-smoke.sh --source-uri file:///absolute/path/to/audio.wav

# reuse a known workdir for iterative debugging
scripts/worker-smoke.sh --workdir /tmp/mod-pipeline-smoke
```

## What the harness creates

Inside the temp work directory:

- `pipeline.sqlite` — isolated smoke-test database
- `artifacts/` — persisted analyzer/normalized/base-chart artifacts
- `logs/` — one log per CLI command
- `mock-analyzer.py` — deterministic one-shot analyzer used for the run

Use `--keep-workdir` when you want to inspect those files after the run.

## Debugging failures

1. rerun with `--keep-workdir`
2. inspect the printed log paths under `logs/`
3. rerun one command at a time with the same exported env vars from the shell script
4. if the failure is Swift build/runtime related on a non-macOS host, treat the shell harness as the intended workflow and fall back to `PipelineRuntimeFixtureTests` on a macOS-capable environment for deeper coverage

## Relationship to existing automated tests

The Swift fixture tests already validate the same pipeline stages in-process via `PipelineRuntimeFixtureTests`. This harness fills the gap at the operator/CLI layer by exercising the real commands and validating the human-facing outputs used during manual smoke checks.
