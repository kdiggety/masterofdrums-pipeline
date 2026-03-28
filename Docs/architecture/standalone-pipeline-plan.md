# Standalone Pipeline Plan

## Repo Review Findings From Existing App

Current `masterofdrums` is a macOS SwiftUI package with these major concerns mixed together:

- gameplay runtime (`GameCore`, `Rendering`, `Audio`, `Input`)
- authoring/admin UI (`AdminChartEditorView`, `RootView` admin navigation)
- chart file persistence (`ChartFileStore`)
- lightweight MIDI ingestion (`MIDIChartLoader`)
- orchestration/controller state (`PrototypeGameController`)

### What Belongs In The Pipeline Project

Move or re-implement these concepts in the pipeline project:

- chart ingestion from MIDI / JSON
- chart normalization and validation
- chart persistence abstractions
- background job state and retries
- workflow orchestration for ingest/process/export tasks
- audit events and operational state

### What Does *Not* Belong In The Pipeline Project

Keep out of the pipeline runtime:

- SwiftUI screens
- SpriteKit/gameplay rendering
- keyboard/hardware gameplay input
- local macOS file chooser UX
- in-process editor-specific controller state

### Extraction Blockers / Coupling

1. `ChartFileStore` depends on `AppKit` open/save panels, so persistence is UI-coupled.
2. `PrototypeGameController` mixes UI state, transport control, chart editing, ingestion, persistence, and gameplay.
3. `MIDIChartLoader` currently returns app-domain `Chart` models directly instead of a transport-neutral ingestion result.
4. No durable storage or job queue exists yet.
5. No standalone CLI/runtime boundary exists yet.

## Recommendation: Separate Repo vs Monorepo

### Recommended now: separate repo

Because the target pipeline is intended to deploy independently and the existing repository is an app prototype, a separate repo is the cleanest short-term move.

Why:

- clearer deployment boundary
- cleaner ownership of operational dependencies
- easier to evolve service concerns without app packaging constraints
- avoids dragging SwiftUI/AppKit dependencies into the pipeline project

## MVP Architecture Recommendation

### Layer 1: Pipeline Runtime
A headless CLI/worker process that:

- boots configuration
- opens SQLite
- applies migrations
- polls queued jobs
- executes work
- records state transitions and retry behavior

### Layer 2: Application / Orchestration
Use cases such as:

- enqueue chart ingest
- claim next runnable job
- mark success/failure
- record workflow events
- request retry/cancel

### Layer 3: Domain
Core durable concepts:

- jobs
- workflows
- workflow events
- source/artifact references
- retry policy and job lifecycle

### Layer 4: Infrastructure
Adapters for:

- SQLite storage
- migrations
- artifact storage references
- logging

## Interface Strategy

### MVP: CLI only
For the first real version, the operational interface should be command-line driven.

Examples:

- `init-db`
- `worker`
- `enqueue-chart-ingest`
- `list-jobs`
- `show-job`
- `retry-job`
- `cancel-job`

### Later: HTTP/API layer if needed
A web/API surface may be added later when an admin UI or remote automation actually needs it.

That future layer should sit on top of the same domain/application/database core and should not change the core orchestration model.

## Migration Strategy

1. Define durable SQLite schema first.
2. Add repository interfaces and SQLite implementations.
3. Add CLI commands for DB bootstrap and workflow operations.
4. Add worker loop and retry handling.
5. Port chart ingestion logic from the app into pipeline adapters.
6. Optionally add HTTP later as a thin transport layer.

## Temporary Compatibility Layer

If needed, the existing macOS app can temporarily:

- continue to edit charts locally
- export/import chart JSON
- invoke the CLI pipeline locally for validation or ingestion

That gives a clean transition path without requiring immediate network APIs.
