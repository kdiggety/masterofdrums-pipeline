import Foundation

// Deferred on purpose.
// The current MVP is CLI + worker + SQLite.
// If an HTTP layer is added later, it should be a thin transport wrapper
// over the same application and database core rather than a new core runtime.
public struct HTTPAPIDeferredPlaceholder {
    public init() {}
}
