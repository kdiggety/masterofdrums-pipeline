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
- operational APIs and audit events

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
5. No external API exists yet; operations are all in-process.

## Recommendation: Separate Repo vs Monorepo

### Recommended now: separate repo

Because the target pipeline is intended to deploy independently and the existing repository is an app prototype, a separate repo is the cleanest short-term move.

Why:

- clearer deployment boundary
- cleaner ownership of operational dependencies
- easier to evolve server concerns without app packaging constraints
- avoids dragging SwiftUI/AppKit dependencies into the service project

### Revisit monorepo later if

- you want shared Swift packages between app and service
- CI/release coordination becomes painful
- common domain contracts stabilize enough to justify workspace consolidation

## Recommended Architecture

### Layer 1: Pipeline Runtime
Worker host, process lifecycle, polling, claiming, retries, shutdown.

### Layer 2: Application / Orchestration
Workflow commands and use cases:

- ingest chart
- validate chart
- persist canonical chart
- request reprocess
- publish job events

### Layer 3: Domain
Core models and policies:

- jobs
- workflows
- charts
- ingestion results
- retry policy
- status transitions

### Layer 4: Infrastructure
Adapters for:

- SQL storage
- artifact storage
- logging
- metrics
- external file/object access

### Layer 5: API Surface
HTTP endpoints for admin UI, macros, and internal operators.

## Future Communication Model

### Admin UI -> Pipeline
Use authenticated HTTP APIs.
Optional later additions:

- SSE/WebSocket job updates
- webhook/event fan-out

### Macros -> Pipeline
Use thin trigger/control commands only:

- enqueue work
- inspect work
- retry/cancel work

Never embed orchestration logic in the macro layer.

## Migration Strategy

1. Extract chart/domain models into transport-neutral service modules.
2. Extract MIDI/JSON ingestion into pipeline adapters.
3. Replace UI-dependent file persistence with repository/storage interfaces.
4. Add durable job store and worker loop.
5. Have the app call pipeline APIs instead of directly owning ingest/persist workflows.

## Temporary Compatibility Layer

If needed, the existing macOS app can temporarily:

- continue to edit charts locally
- export/import chart JSON
- optionally call the new service for validation/ingestion first

That gives you a transitional bridge without forcing a full cutover.
