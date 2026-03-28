# API Interface Outline (Deferred)

This document is intentionally deferred.

The current MVP direction for `masterofdrums-pipeline` is:

1. SQLite first
2. CLI operational surface first
3. worker/runtime first
4. no immediate web server implementation

A future HTTP/API layer may still be added later for:

- admin UI integration
- macro/automation triggers
- remote operational control

If/when that happens, the API should wrap the same domain/application/database core rather than introducing new orchestration logic.

For the active MVP interface, see:

- `Docs/interfaces/cli-interface-outline.md`
- `Docs/database/sqlite-schema.md`
