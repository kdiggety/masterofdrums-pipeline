# API Interface Outline

## Health

### `GET /healthz`
Liveness check.

### `GET /readyz`
Readiness check.

## Jobs

### `POST /v1/jobs/chart-ingest`
Create a chart ingestion job.

Request body:

```json
{
  "sourceType": "midi|chart-json|audio+chart",
  "sourceUri": "file:///tmp/example.mid",
  "requestedBy": "admin-ui|macro|system",
  "idempotencyKey": "optional-string",
  "metadata": {
    "trackId": "optional",
    "chartId": "optional"
  }
}
```

Response:

```json
{
  "jobId": "job_123",
  "workflowId": "wf_123",
  "status": "queued"
}
```

### `GET /v1/jobs/{jobId}`
Fetch job status, attempts, timestamps, and last error.

### `POST /v1/jobs/{jobId}/retry`
Request manual retry.

### `POST /v1/jobs/{jobId}/cancel`
Request cancellation.

## Workflows

### `GET /v1/workflows/{workflowId}`
Fetch workflow state and child jobs.

### `GET /v1/workflows/{workflowId}/events`
Fetch timeline/audit events.

## Admin Operations

### `POST /v1/admin/workers/pause`
Pause worker consumption.

### `POST /v1/admin/workers/resume`
Resume worker consumption.

### `GET /v1/admin/runtime`
Return runtime, queue, and storage state summary.

## Auth

Initial recommendation:

- token-based auth for service-to-service calls
- optional unauthenticated local development mode
- later: scoped service accounts / JWT / mTLS depending on deployment model
