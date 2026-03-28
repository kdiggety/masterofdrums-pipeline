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
- `masterofdrums-pipeline enqueue-chart-ingest --source-uri ...`
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

3. `enqueue-chart-ingest`
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

Still to implement:

- worker loop
- chart ingestion port from the main app
- retry policies and state transitions

## Current Testable Slice

The repo is now aimed at a first testable CLI + SQLite slice:

1. `init-db`
2. `enqueue-chart-ingest`
3. `list-jobs`
4. `show-job`

Example flow:

```bash
swift run MasterOfDrumsPipeline init-db
swift run MasterOfDrumsPipeline enqueue-chart-ingest --source-uri file:///tmp/test.mid --source-type midi --requested-by cli
swift run MasterOfDrumsPipeline list-jobs
swift run MasterOfDrumsPipeline show-job <job-id>
```

Note: this assumes Swift and SQLite development libraries are available on the machine.

See `Docs/architecture/standalone-pipeline-plan.md`, `Docs/database/sqlite-schema.md`, and `Docs/interfaces/cli-interface-outline.md`.
