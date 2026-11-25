import Foundation
import Testing
import CSQLite
@testable import JournalCore

struct NotebookSavePerformanceTests {
    private func fixture(_ body: (JournalStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("journal.sqlite")
        try body(JournalStore(url: url), url)
    }

    @Test func consecutiveSavesDoNotScanUnchangedLibraryRows() throws {
        try fixture { store, _ in
            let notes = (0..<1_200).map { NoteDocument(title: "Synthetic \($0)", markdown: "Unchanged content") }
            _ = try store.importNotebook(NotebookSnapshot(notes: notes))
            var selected = try store.notes().first!
            selected.markdown = "First edit"
            selected = try store.saveNote(selected, expectedRevision: selected.revision)

            let scans = FullScanCounter()
            let db = try store.withStatement("SELECT 1") { sqlite3_db_handle($0) }
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement else { return 0 }
                let counter = Unmanaged<FullScanCounter>.fromOpaque(context).takeUnretainedValue()
                counter.rows += Int(sqlite3_stmt_status(OpaquePointer(statement), SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
                return 0
            }, Unmanaged.passUnretained(scans).toOpaque())
            defer { sqlite3_trace_v2(db, 0, nil, nil) }

            selected.markdown = "Second edit"
            let saved = try store.saveNote(selected, expectedRevision: selected.revision)
            #expect(saved.markdown == "Second edit")
            #expect(saved.revision == selected.revision + 1)
            #expect(scans.rows < 100, "A consecutive save scanned \(scans.rows) unchanged rows")
        }
    }

    @Test func externalChangesInvalidatePriorValidationBeforeSaving() throws {
        try fixture { store, url in
            let other = try store.saveNote(NoteDocument(title: "Other note"))
            var selected = try store.saveNote(NoteDocument(title: "Selected"))
            selected.markdown = "Warm validation"
            selected = try store.saveNote(selected, expectedRevision: selected.revision)
            let external = try JournalStore(url: url)
            try external.execute("UPDATE notes SET payload='invalid JSON' WHERE id=?", values: [other.id.uuidString])
            selected.markdown = "Must not save over an unchecked library"
            #expect(throws: (any Error).self) { try store.saveNote(selected, expectedRevision: selected.revision) }
            try external.execute("UPDATE notes SET payload=? WHERE id=?", values: [try external.payload(other), other.id.uuidString])
            #expect(try store.notes().first(where: { $0.id == selected.id })?.markdown == "Warm validation")
            let saved = try store.saveNote(selected, expectedRevision: selected.revision)
            #expect(saved.markdown == selected.markdown)
        }
    }

    @Test func localChangesInvalidatePriorValidationAndFailedSavesKeepRevision() throws {
        try fixture { store, _ in
            let folder = NoteFolder(name: "Folder")
            try store.saveNoteFolder(folder)
            let other = try store.saveNote(NoteDocument(folderID: folder.id, title: "Other note"))
            var selected = try store.saveNote(NoteDocument(title: "Selected"))
            selected.markdown = "Warm validation"
            selected = try store.saveNote(selected, expectedRevision: selected.revision)
            var orphan = other; orphan.folderID = UUID()
            try store.execute("UPDATE notes SET payload=? WHERE id=?", values: [try store.payload(orphan), other.id.uuidString])
            selected.markdown = "Later edit"
            #expect(throws: (any Error).self) { try store.saveNote(selected, expectedRevision: selected.revision) }
            try store.execute("UPDATE notes SET payload=? WHERE id=?", values: [try store.payload(other), other.id.uuidString])
            let saved = try store.saveNote(selected, expectedRevision: selected.revision)
            #expect(saved.revision == selected.revision + 1)
            #expect(throws: (any Error).self) { try store.saveNote(selected, expectedRevision: selected.revision) }
        }
    }

    @Test func reusedValidationStillChecksCurrentReferencesAndDirectory() throws {
        try fixture { store, _ in
            var selected = try store.saveNote(NoteDocument(title: "Selected"))
            let other = try store.saveNote(NoteDocument(title: "Other"))
            let owned = NoteAsset(ownerNoteID: selected.id, data: Data([1]))
            let foreign = NoteAsset(ownerNoteID: other.id, data: Data([2]))
            try store.saveNoteAsset(owned); try store.saveNoteAsset(foreign)
            selected.markdown = "[owned](\(owned.reference))"
            selected = try store.saveNote(selected, expectedRevision: selected.revision)

            var invalid = selected; invalid.markdown = "[foreign](\(foreign.reference))"
            #expect(throws: (any Error).self) { try store.saveNote(invalid, expectedRevision: selected.revision) }
            invalid = selected; invalid.folderID = UUID()
            #expect(throws: (any Error).self) { try store.saveNote(invalid, expectedRevision: selected.revision) }
            invalid = selected; invalid.title = "Invalid\nTitle"
            #expect(throws: (any Error).self) { try store.saveNote(invalid, expectedRevision: selected.revision) }
            #expect(try store.notes().first(where: { $0.id == selected.id }) == selected)
            #expect(try store.noteAsset(id: owned.id) == owned)
        }
    }
}

private final class FullScanCounter {
    var rows = 0
}
