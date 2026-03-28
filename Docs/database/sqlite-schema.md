# SQLite Schema

This document defines the initial SQLite schema for the pipeline MVP.

## Goals

The database is the durable system of record for:

- workflow state
- jobs and retries
- event history
- source/artifact references
- idempotent enqueue requests

## Design Notes

1. SQLite is the first real database for MVP.
2. The app creates the database file itself.
3. The app applies migrations itself.
4. Large artifacts stay on disk/object storage; SQLite stores metadata and references.

## Tables

### `schema_migrations`
Tracks applied migrations.

| column | type | notes |
|---|---|---|
| version | text primary key | migration id |
| applied_at | text not null | ISO8601 timestamp |

### `workflows`
Top-level workflow execution records.

| column | type | notes |
|---|---|---|
| id | text primary key | workflow UUID/string id |
| name | text not null | e.g. `chart-ingest` |
| status | text not null | queued/running/succeeded/failed/cancelled |
| requested_by | text | cli/app/macro/system |
| idempotency_key | text | optional external dedupe key |
| created_at | text not null | ISO8601 timestamp |
| updated_at | text not null | ISO8601 timestamp |
| started_at | text | first execution start |
| completed_at | text | terminal completion time |
| last_error | text | most recent workflow-level error |

Indexes:

- `idx_workflows_status_created_at(status, created_at)`
- unique partial/regular index on `idempotency_key` when present

### `jobs`
Individual executable jobs within a workflow.

| column | type | notes |
|---|---|---|
| id | text primary key | job UUID/string id |
| workflow_id | text not null | fk -> workflows.id |
| type | text not null | chart_ingest/chart_validate/chart_export |
| status | text not null | queued/running/succeeded/failed/cancelled |
| attempt | integer not null default 0 | current attempt count |
| max_attempts | integer not null | retry ceiling |
| priority | integer not null default 100 | lower = sooner if desired |
| run_after | text not null | when job becomes runnable |
| claimed_at | text | when worker claimed the job |
| claimed_by | text | worker id/host |
| created_at | text not null | ISO8601 timestamp |
| updated_at | text not null | ISO8601 timestamp |
| started_at | text | execution start |
| completed_at | text | terminal completion time |
| last_error | text | most recent failure |
| payload_json | text not null | serialized command payload |
| result_json | text | serialized result summary |

Indexes:

- `idx_jobs_workflow_id(workflow_id)`
- `idx_jobs_status_run_after_priority(status, run_after, priority)`
- `idx_jobs_claimed_by(claimed_by)`

### `workflow_events`
Append-only timeline for audit and troubleshooting.

| column | type | notes |
|---|---|---|
| id | text primary key | event UUID/string id |
| workflow_id | text not null | fk -> workflows.id |
| job_id | text | fk -> jobs.id, optional |
| event_type | text not null | workflow_created/job_enqueued/job_started/job_failed/etc |
| message | text | human-readable summary |
| details_json | text | structured metadata |
| created_at | text not null | ISO8601 timestamp |

Indexes:

- `idx_workflow_events_workflow_id_created_at(workflow_id, created_at)`
- `idx_workflow_events_job_id(job_id)`

### `artifacts`
References to source or generated files.

| column | type | notes |
|---|---|---|
| id | text primary key | artifact UUID/string id |
| workflow_id | text | fk -> workflows.id |
| job_id | text | fk -> jobs.id |
| artifact_type | text not null | source_midi/source_chart_json/canonical_chart/etc |
| uri | text not null | file path or object URI |
| content_type | text | mime/logical type |
| checksum | text | optional digest |
| metadata_json | text | structured metadata |
| created_at | text not null | ISO8601 timestamp |

Indexes:

- `idx_artifacts_workflow_id(workflow_id)`
- `idx_artifacts_job_id(job_id)`
- `idx_artifacts_artifact_type(artifact_type)`

### `idempotency_keys`
Maps external enqueue keys to existing workflows/jobs.

| column | type | notes |
|---|---|---|
| idempotency_key | text primary key | caller-provided dedupe key |
| workflow_id | text not null | fk -> workflows.id |
| job_id | text | optional fk -> jobs.id |
| request_fingerprint | text | optional payload digest |
| created_at | text not null | ISO8601 timestamp |

## Initial SQL

See `Resources/sql/001_initial_schema.sql` for the first migration.
