PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS workflows (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL,
    requested_by TEXT,
    idempotency_key TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    last_error TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workflows_idempotency_key
    ON workflows(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_workflows_status_created_at
    ON workflows(status, created_at);

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    type TEXT NOT NULL,
    status TEXT NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL,
    priority INTEGER NOT NULL DEFAULT 100,
    run_after TEXT NOT NULL,
    claimed_at TEXT,
    claimed_by TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    last_error TEXT,
    payload_json TEXT NOT NULL,
    result_json TEXT,
    FOREIGN KEY (workflow_id) REFERENCES workflows(id)
);

CREATE INDEX IF NOT EXISTS idx_jobs_workflow_id
    ON jobs(workflow_id);

CREATE INDEX IF NOT EXISTS idx_jobs_status_run_after_priority
    ON jobs(status, run_after, priority);

CREATE INDEX IF NOT EXISTS idx_jobs_claimed_by
    ON jobs(claimed_by);

CREATE TABLE IF NOT EXISTS workflow_events (
    id TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    job_id TEXT,
    event_type TEXT NOT NULL,
    message TEXT,
    details_json TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (workflow_id) REFERENCES workflows(id),
    FOREIGN KEY (job_id) REFERENCES jobs(id)
);

CREATE INDEX IF NOT EXISTS idx_workflow_events_workflow_id_created_at
    ON workflow_events(workflow_id, created_at);

CREATE INDEX IF NOT EXISTS idx_workflow_events_job_id
    ON workflow_events(job_id);

CREATE TABLE IF NOT EXISTS artifacts (
    id TEXT PRIMARY KEY,
    workflow_id TEXT,
    job_id TEXT,
    artifact_type TEXT NOT NULL,
    uri TEXT NOT NULL,
    content_type TEXT,
    checksum TEXT,
    metadata_json TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (workflow_id) REFERENCES workflows(id),
    FOREIGN KEY (job_id) REFERENCES jobs(id)
);

CREATE INDEX IF NOT EXISTS idx_artifacts_workflow_id
    ON artifacts(workflow_id);

CREATE INDEX IF NOT EXISTS idx_artifacts_job_id
    ON artifacts(job_id);

CREATE INDEX IF NOT EXISTS idx_artifacts_artifact_type
    ON artifacts(artifact_type);

CREATE TABLE IF NOT EXISTS idempotency_keys (
    idempotency_key TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    job_id TEXT,
    request_fingerprint TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (workflow_id) REFERENCES workflows(id),
    FOREIGN KEY (job_id) REFERENCES jobs(id)
);
