import Foundation
import Testing
import CSQLite
@testable import JournalCore

struct RecoveryTests {
    private func fixture(_ body: (JournalStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body(JournalStore(url: root.appendingPathComponent("journal.sqlite")), root)
    }
    private func sql(_ url: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?; sqlite3_open(url.path, &db); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw JournalError.invalid("fixture SQL") }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw JournalError.invalid("fixture step") }
        return status == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }
    @Test func savesEarlierContentInFullBackup() throws {
        try fixture { store, _ in
            var note = try store.saveNote(NoteDocument(title: "原始标题", markdown: "原始正文"))
            note.markdown = "修改后的正文"
            _ = try store.saveNote(note, expectedRevision: note.revision)
            let object = try #require(JSONSerialization.jsonObject(with: store.exportBackup()) as? [String: Any])
            let notebook = try #require(object["notebook"] as? [String: Any])
            let history = try #require(notebook["history"] as? [[String: Any]])
            #expect(history.count == 1)
            #expect(history.first?["markdown"] as? String == "原始正文")
        }
    }
    @Test func upgradesV5WithVerifiedOriginalSnapshot() throws {
        try fixture { store, root in
            let note = try store.saveNote(NoteDocument(title: "Existing"))
            let url = root.appendingPathComponent("journal.sqlite")
            _ = try sql(url, "DROP TABLE IF EXISTS note_history")
            _ = try sql(url, "PRAGMA user_version=5")
            let upgraded = try JournalStore(url: url)
            #expect(try sql(url, "PRAGMA user_version") == 6)
            let snapshot = try #require(upgraded.migrationBackupURL)
            #expect(try sql(snapshot, "PRAGMA user_version") == 5)
            #expect(try sql(snapshot, "SELECT count(*) FROM notes") == 1)
            #expect(try upgraded.notes() == [note])
        }
    }
    @Test func futureDatabaseIsNeverMutated() throws {
        try fixture { _, root in
            let url = root.appendingPathComponent("journal.sqlite")
            _ = try sql(url, "PRAGMA user_version=7")
            #expect(throws: (any Error).self) { try JournalStore(url: url) }
            #expect(try sql(url, "PRAGMA user_version") == 7)
        }
    }
    @Test func coalescingKeepsFirstPreEditStateAndResumesAfterFiveMinutes() throws {
        try fixture { store, root in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var note = try store.saveNote(NoteDocument(title: "A", markdown: "first"), now: start)
            note.markdown = "second"; note = try store.saveNote(note, now: start.addingTimeInterval(1))
            note.markdown = "third"; note = try store.saveNote(note, now: start.addingTimeInterval(20))
            #expect(try store.noteHistory(noteID: note.id).map(\.markdown) == ["first"])
            note = try store.saveNote(note, now: start.addingTimeInterval(400))
            #expect(try store.noteHistory(noteID: note.id).count == 1)
            note.title = "B"; note = try store.saveNote(note, now: start.addingTimeInterval(401))
            let reopened = try JournalStore(url: root.appendingPathComponent("journal.sqlite"))
            #expect(try reopened.noteHistory(noteID: note.id).map(\.markdown) == ["third", "first"])
        }
    }
    @Test func restorePreservesCurrentBodyAndRejectsStaleRevision() throws {
        try fixture { store, _ in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var note = try store.saveNote(NoteDocument(title: "Old", markdown: "old"), now: start)
            note.title = "Current"; note.markdown = "current"; note = try store.saveNote(note, now: start.addingTimeInterval(1))
            let old = try #require(store.noteHistory(noteID: note.id).first)
            #expect(throws: (any Error).self) { try store.restoreNoteVersion(noteID: note.id, versionID: old.id, expectedRevision: 1) }
            #expect(try store.noteHistory(noteID: note.id).count == 1)
            let restored = try store.restoreNoteVersion(noteID: note.id, versionID: old.id, expectedRevision: note.revision, now: start.addingTimeInterval(2))
            #expect(restored.title == "Old" && restored.markdown == "old" && restored.revision == 3)
            let latest = try #require(store.noteHistory(noteID: note.id).first)
            #expect(latest.markdown == "current" && latest.reason == .beforeRestore)
        }
    }
    @Test func restoreProtectsCurrentTextWhenImportedHistoryContainsFutureDates() throws {
        try fixture { store, _ in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let note = try store.saveNote(NoteDocument(title: "Current", markdown: "must remain recoverable"), now: now)
            let earliest = NoteVersion(noteID: note.id, title: "First", markdown: "first", savedAt: now.addingTimeInterval(-100), sourceRevision: 0)
            try store.persistNoteVersion(earliest)
            for index in 1...99 {
                try store.persistNoteVersion(NoteVersion(noteID: note.id, title: "Future", markdown: "future \(index)", savedAt: now.addingTimeInterval(Double(index) * 1000), sourceRevision: 0))
            }
            _ = try store.restoreNoteVersion(noteID: note.id, versionID: earliest.id, expectedRevision: note.revision, now: now)
            let history = try store.noteHistory(noteID: note.id)
            #expect(history.count <= NotebookHistoryPolicy.maximumVersions)
            #expect(history.contains { $0.id == earliest.id })
            #expect(history.contains { $0.markdown == "must remain recoverable" && $0.reason == .beforeRestore })
        }
    }
    @Test func manualCheckpointsAreBoundedAndEarliestRemainsRecoverable() throws {
        try fixture { store, _ in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var note = try store.saveNote(NoteDocument(markdown: "first"), now: start)
            _ = try store.checkpointNote(id: note.id, now: start)
            for index in 1...110 {
                note.markdown = "version \(index)"; note = try store.saveNote(note, now: start.addingTimeInterval(Double(index)))
                _ = try store.checkpointNote(id: note.id, now: start.addingTimeInterval(Double(index)))
            }
            let history = try store.noteHistory(noteID: note.id)
            #expect(history.count <= 100)
            #expect(history.last?.markdown == "first")
            #expect(history.contains { $0.markdown == "version 110" })
        }
    }
    @Test func historyAndDetachedAssetSurviveBackupAndSameIDMerge() throws {
        try fixture { store, root in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var note = try store.saveNote(NoteDocument(markdown: "before"), now: start)
            let asset = NoteAsset(ownerNoteID: note.id, data: Data([1, 0, 255]))
            try store.saveNoteAsset(asset)
            note.markdown = "[asset](\(asset.reference))"; note = try store.saveNote(note, now: start.addingTimeInterval(1))
            let checkpoint = try store.checkpointNote(id: note.id, now: start.addingTimeInterval(2))
            note.markdown = "removed attachment"; note = try store.saveNote(note, now: start.addingTimeInterval(3))
            let target = try JournalStore(url: root.appendingPathComponent("restored.sqlite"))
            var local = NoteDocument(id: note.id, title: "Keep local", markdown: "local body")
            local = try target.saveNote(local)
            _ = try target.importBackup(store.exportBackup())
            #expect(try target.notes().first?.markdown == "local body")
            #expect(try target.noteAsset(id: asset.id)?.data == Data([1, 0, 255]))
            let restored = try target.restoreNoteVersion(noteID: note.id, versionID: checkpoint.id, expectedRevision: local.revision)
            #expect(restored.markdown == "[asset](\(asset.reference))")
            try target.deleteNote(id: note.id); try target.permanentlyDeleteNote(id: note.id)
            #expect(try target.noteHistory(noteID: note.id).isEmpty)
        }
    }
    @Test func historicalAssetsCannotBeOverwritten() throws {
        try fixture { store, _ in
            var note = try store.saveNote(NoteDocument())
            var asset = NoteAsset(ownerNoteID: note.id, data: Data([1, 2]))
            try store.saveNoteAsset(asset)
            note.markdown = "[file](\(asset.reference))"; note = try store.saveNote(note)
            _ = try store.checkpointNote(id: note.id)
            asset.data = Data([9])
            #expect(throws: (any Error).self) { try store.saveNoteAsset(asset) }
            #expect(try store.noteAsset(id: asset.id)?.data == Data([1, 2]))
        }
    }
    @Test func invalidHistoryCannotPartiallyImportBackup() throws {
        try fixture { store, root in
            var note = try store.saveNote(NoteDocument(markdown: "old"))
            note.markdown = "new"; _ = try store.saveNote(note)
            var object = try #require(JSONSerialization.jsonObject(with: store.exportBackup()) as? [String: Any])
            var notebook = try #require(object["notebook"] as? [String: Any])
            var history = try #require(notebook["history"] as? [[String: Any]])
            history[0]["markdown"] = "[missing](workjournal-asset://\(note.id)/\(UUID()))"
            notebook["history"] = history; object["notebook"] = notebook
            let target = try JournalStore(url: root.appendingPathComponent("empty.sqlite"))
            #expect(throws: (any Error).self) { try target.importBackup(JSONSerialization.data(withJSONObject: object)) }
            #expect(try target.notes().isEmpty)
        }
    }

    @Test func conflictingHistoryAssetCannotReplaceOrMisrepresentLocalBytes() throws {
        try fixture { source, root in
            var note = try source.saveNote(NoteDocument())
            let asset = NoteAsset(ownerNoteID: note.id, data: Data([1, 2]))
            try source.saveNoteAsset(asset)
            note.markdown = "[file](\(asset.reference))"; _ = try source.saveNote(note)
            _ = try source.checkpointNote(id: note.id)
            let target = try JournalStore(url: root.appendingPathComponent("target.sqlite"))
            _ = try target.saveNote(NoteDocument(id: note.id))
            var different = asset; different.data = Data([9])
            try target.saveNoteAsset(different)
            #expect(throws: (any Error).self) { try target.importBackup(source.exportBackup()) }
            #expect(try target.noteAsset(id: asset.id)?.data == Data([9]))
            #expect(try target.noteHistory(noteID: note.id).isEmpty)
        }
    }

}
