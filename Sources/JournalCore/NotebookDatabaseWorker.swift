import Foundation

func checkNotebookCancellation(_ cancelled: () -> Bool) throws {
    if cancelled() { throw CancellationError() }
}

/// Owns one independent connection on the actor executor. Initialization is lazy,
/// so constructing this worker on the main actor performs no filesystem/SQLite work.
public actor NotebookDatabaseWorker {
    private let url: URL
    private var store: JournalStore?
    public init(url: URL) { self.url = url }
    private func database() throws -> JournalStore {
        try Task.checkCancellation()
        if let store { return store }
        let opened = try JournalStore(url: url)
        store = opened
        return opened
    }
    public func importNotebook(_ snapshot: NotebookSnapshot) async throws -> NotebookImportResult {
        try Task.checkCancellation()
        return try database().importNotebook(snapshot, cancelled: { Task.isCancelled })
    }
    public func snapshot(noteIDs: Set<UUID>, folderIDs: Set<UUID>) async throws -> NotebookSnapshot {
        try Task.checkCancellation()
        return try database().selectedNotebookSnapshot(noteIDs: noteIDs, folderIDs: folderIDs, cancelled: { Task.isCancelled })
    }
}
