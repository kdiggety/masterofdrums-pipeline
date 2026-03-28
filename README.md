# MasterOfDrums Pipeline

Standalone pipeline/service project for background processing, chart ingestion, workflow orchestration, and operational APIs.

## Purpose

This repository is the system of record for background processing and business workflow related to MasterOfDrums.

It is intentionally independent from:

- the macOS gameplay/admin app
- any future web/admin UI
- macro/automation triggers

Those systems should call into this service through stable APIs/events, not host the core runtime.

## Initial Scope

Phase 1 focuses on creating the standalone service boundary and core module structure for:

- chart ingestion
- chart normalization/validation
- job orchestration
- durable job state
- observability
- operational control APIs

## Recommended Runtime

Because the current product code is already Swift-based, the recommended first implementation is a Swift server/service using Swift Package Manager, with modules separated for domain logic, application services, infrastructure, and HTTP APIs.

Suggested stack:

- Swift 5.9+
- Swift Package Manager
- Async/await + actors for concurrency boundaries
- SQLite or Postgres for durable state
- Structured JSON logging
- OpenTelemetry-compatible observability later

## Architectural Principles

1. Pipeline is deployable on its own.
2. Admin UI is optional and external.
3. Macros/automations trigger work, but do not become the workflow engine.
4. Background jobs are durable, retryable, and inspectable.
5. Domain logic stays reusable and transport-agnostic.

## Proposed Modules

- `PipelineDomain` — core entities and workflow contracts
- `PipelineApplication` — use cases / orchestration services
- `PipelineInfrastructure` — persistence, queues, adapters, logging
- `PipelineHTTP` — operational/admin-facing API surface
- `PipelineRuntime` — worker runtime and bootstrap
- `PipelineService` — executable entry point

## Project Layout

```text
Sources/
  PipelineDomain/
  PipelineApplication/
  PipelineInfrastructure/
  PipelineHTTP/
  PipelineRuntime/
  PipelineService/
Docs/
  architecture/
  api/
Config/
  pipeline.example.env
```

## Example Responsibilities

### Runtime
- start workers
- poll/claim jobs
- execute retries/backoff
- expose health/ready state

### Orchestration
- submit ingest/process/publish jobs
- coordinate multi-step workflows
- enforce idempotency

### Storage / State
- jobs
- workflow executions
- artifacts/asset references
- audit trail / events

### API Surface
- create jobs
- query job/workflow status
- trigger reprocess/retry/cancel actions
- manage health/admin operations

## Admin UI Integration

The future admin UI should communicate with this service over authenticated HTTP APIs and/or event streams.

The UI should:

- submit commands
- read workflow/job status
- inspect artifacts, logs, and failures

The UI should not:

- own workflow state
- run background work itself
- become the source of truth for retries or orchestration

## Macro / Automation Integration

Macros should act only as external trigger/control clients.

Examples:

- enqueue chart ingestion
- request reprocessing for a track
- pause/resume a worker class
- annotate a workflow with metadata

Macros should not contain the business workflow logic itself.

## Bootstrap

1. Fill in persistence implementation.
2. Add HTTP server package and wire endpoints.
3. Add worker loop + retry policy.
4. Add ingestion adapters for current chart formats.
5. Connect main app/admin UI as an API client instead of embedding authoring workflow logic.

See `Docs/architecture/standalone-pipeline-plan.md` and `Docs/api/interface-outline.md`.
