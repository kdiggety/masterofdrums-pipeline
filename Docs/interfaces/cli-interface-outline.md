# CLI Interface Outline

## Core Commands

### `masterofdrums-pipeline init-db`
Create the SQLite database file if needed and apply migrations.

### `masterofdrums-pipeline worker`
Start the worker loop.

Responsibilities:

- apply startup migrations when enabled
- poll queued jobs
- claim runnable jobs
- execute job handlers
- persist retries and failures

### `masterofdrums-pipeline enqueue-chart-ingest --source-uri <uri> [--source-type midi] [--requested-by cli] [--idempotency-key <key>]`
Create a workflow plus the initial chart-ingest job.

### `masterofdrums-pipeline list-jobs [--status queued|running|failed|succeeded]`
List jobs from the database.

### `masterofdrums-pipeline show-job <job-id>`
Show one job with payload, result, timestamps, and error state.

### `masterofdrums-pipeline retry-job <job-id>`
Requeue a failed job.

### `masterofdrums-pipeline cancel-job <job-id>`
Cancel a queued or running job if policy allows.

## Notes

1. CLI is the MVP operational surface.
2. A future HTTP/API interface should wrap the same application layer rather than replacing it.
3. Commands should remain safe, explicit, and scriptable.
