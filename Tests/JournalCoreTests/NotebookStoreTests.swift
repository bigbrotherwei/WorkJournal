import Foundation
import Testing
import CSQLite
@testable import JournalCore

struct NotebookStoreTests {
    private func fixture(_ body: (JournalStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-\(UUID())")
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
    @Test func modelRoundTripAndResourceIdentity() throws {
        let note = NoteDocument(title: "合成笔记", markdown: "# 原文", tags: ["synthetic"], source: "markdown")
        let asset = NoteAsset(ownerNoteID: note.id, fileName: "sample.pdf", mimeType: "application/pdf", kind: .pdf, data: Data([0,1,255]))
        let snapshot = NotebookSnapshot(folders: [NoteFolder(name: "目录")], notes: [note], assets: [asset])
        #expect(try JSONDecoder().decode(NotebookSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        #expect(asset.reference.lowercased() == "workjournal-asset://\(note.id.uuidString)/\(asset.id.uuidString)".lowercased())
    }
    @Test func validatesParentsCyclesDepthAndOwnership() throws {
        try fixture { store, _ in
            let root = NoteFolder(name: "Root"); try store.saveNoteFolder(root)
            let child = NoteFolder(parentID: root.id, name: "Child"); try store.saveNoteFolder(child)
            var cycle = root; cycle.parentID = child.id
            #expect(throws: (any Error).self) { try store.saveNoteFolder(cycle) }
            #expect(throws: (any Error).self) { try store.saveNoteFolder(NoteFolder(parentID: UUID(), name: "Orphan")) }
            #expect(throws: (any Error).self) { try store.saveNoteFolder(NoteFolder(name: "  ")) }
            var parent = child.id
            for index in 3...16 { let folder = NoteFolder(parentID: parent, name: "Depth \(index)"); try store.saveNoteFolder(folder); parent = folder.id }
            #expect(throws: (any Error).self) { try store.saveNoteFolder(NoteFolder(parentID: parent, name: "Too deep")) }
            #expect(throws: (any Error).self) { try store.saveNoteAsset(NoteAsset(ownerNoteID: UUID(), fileName: "x", mimeType: "image/png", kind: .image, data: Data([1]))) }
            let first = try store.saveNote(NoteDocument(title: "First")); let second = try store.saveNote(NoteDocument(title: "Second"))
            let asset = NoteAsset(ownerNoteID: first.id, fileName: "x.png", mimeType: "image/png", kind: .image, data: Data([1]))
            try store.saveNoteAsset(asset)
            var wrong = second; wrong.markdown = "![](\(asset.reference))"
            #expect(throws: (any Error).self) { try store.saveNote(wrong) }
            var absent = first; absent.markdown = "![](workjournal-asset://\(first.id)/\(UUID()))"
            #expect(throws: (any Error).self) { try store.saveNote(absent) }
        }
    }
    @Test func revisionsRejectStaleWritesAndPreserveAssetBlob() throws {
        try fixture { store, root in
            let initial = try store.saveNote(NoteDocument(title: "Original"), expectedRevision: 0)
            #expect(initial.revision == 1)
            let asset = NoteAsset(ownerNoteID: initial.id, fileName: "original.pdf", mimeType: "application/pdf", kind: .pdf, data: Data([0,255,5,4]))
            try store.saveNoteAsset(asset)
            let database = root.appendingPathComponent("journal.sqlite")
            _ = try sql(database, "CREATE TRIGGER no_asset_update BEFORE UPDATE ON note_assets BEGIN SELECT RAISE(ABORT,'asset rewritten'); END")
            var updated = initial; updated.markdown = "[original](\(asset.reference))"
            let saved = try store.saveNote(updated, expectedRevision: 1)
            #expect(saved.revision == 2)
            #expect(throws: (any Error).self) { try store.saveNote(initial, expectedRevision: 1) }
            #expect(try store.noteAsset(id: asset.id) == asset)
            #expect(try store.notes().first?.markdown == updated.markdown)
            #expect(try sql(database, "SELECT count(*) FROM note_assets WHERE typeof(data)='blob'") == 1)
        }
    }
    @Test func deletionBatchRestoresOnlyItsOwnLiveSubtree() throws {
        try fixture { store, _ in
            let root = NoteFolder(name: "Root"); let child = NoteFolder(parentID: root.id, name: "Child")
            try store.saveNoteFolder(root); try store.saveNoteFolder(child)
            let earlier = try store.saveNote(NoteDocument(folderID: child.id, title: "Earlier trash"))
            let current = try store.saveNote(NoteDocument(folderID: child.id, title: "Current"))
            try store.deleteNote(id: earlier.id); try store.deleteNoteFolder(id: root.id)
            #expect(try store.notes().isEmpty); #expect(try store.noteFolders().isEmpty)
            try store.restoreNoteFolder(id: root.id)
            #expect(try store.notes().map(\.id) == [current.id])
            #expect(try store.notes(includeDeleted: true).first(where: { $0.id == earlier.id })?.deletedAt != nil)
            try store.deleteNoteFolder(id: root.id); try store.restoreNote(id: current.id)
            #expect(try store.notes().first?.folderID == nil)
        }
    }
    @Test func permanentFolderDeletionCleansOwnedAssets() throws {
        try fixture { store, _ in
            let folder = NoteFolder(name: "Folder"); try store.saveNoteFolder(folder)
            let note = try store.saveNote(NoteDocument(folderID: folder.id))
            let asset = NoteAsset(ownerNoteID: note.id, fileName: "x", mimeType: "application/octet-stream", data: Data([1]))
            try store.saveNoteAsset(asset)
            #expect(throws: (any Error).self) { try store.permanentlyDeleteNote(id: note.id) }
            try store.deleteNoteFolder(id: folder.id); try store.permanentlyDeleteNoteFolder(id: folder.id)
            #expect(try store.notebookSnapshot() == NotebookSnapshot())
            #expect(try store.noteAsset(id: asset.id) == nil)
        }
    }
    @Test func invalidImportIsAtomicAndRejectsDuplicateIDs() throws {
        try fixture { store, _ in
            let root = NoteFolder(name: "Incoming")
            let invalid = NoteDocument(folderID: UUID(), title: "Orphan")
            #expect(throws: (any Error).self) { try store.importNotebook(NotebookSnapshot(folders: [root], notes: [invalid])) }
            #expect(try store.notebookSnapshot() == NotebookSnapshot())
            #expect(throws: (any Error).self) { try store.importNotebook(NotebookSnapshot(folders: [root, root])) }
            let note = NoteDocument()
            let asset = NoteAsset(ownerNoteID: note.id, fileName: "x", mimeType: "image/png", kind: .image, data: Data([1]))
            var referenced = note; referenced.markdown = "![](\(asset.reference))"
            let result = try store.importNotebook(NotebookSnapshot(folders: [root], notes: [referenced], assets: [asset]))
            #expect(result.folders == 1 && result.notes == 1 && result.assets == 1)
        }
    }
    @Test func backupIncludesTrashExactAssetBytesAndOldFormatsRemainReadable() throws {
        try fixture { store, root in
            let folder = NoteFolder(name: "Folder"); try store.saveNoteFolder(folder)
            let note = try store.saveNote(NoteDocument(folderID: folder.id, tags: ["tag"], sourceFingerprint: "fingerprint"))
            let asset = NoteAsset(ownerNoteID: note.id, fileName: "original.pdf", mimeType: "application/pdf", kind: .pdf, data: Data([0,255,0,20]))
            try store.saveNoteAsset(asset); try store.deleteNoteFolder(id: folder.id)
            let copy = try JournalStore(url: root.appendingPathComponent("copy.sqlite"))
            _ = try copy.importBackup(store.exportBackup())
            #expect(try copy.notebookSnapshot() == store.notebookSnapshot())
            #expect(try copy.noteAsset(id: asset.id)?.data == asset.data)
            for version in 1...4 {
                _ = try copy.importBackup(Data("{\"formatVersion\":\(version),\"entries\":[],\"reports\":[]}".utf8))
            }
        }
    }
    @Test func localDeletedParentsSkipIncomingBranchesAndLocalNoteAssets() throws {
        try fixture { store, _ in
            let folder = NoteFolder(name: "Local folder"); try store.saveNoteFolder(folder)
            let existing = try store.saveNote(NoteDocument(title: "Local content"))
            try store.deleteNoteFolder(id: folder.id)
            let child = NoteFolder(parentID: folder.id, name: "Incoming child")
            let note = NoteDocument(folderID: child.id, title: "Skipped")
            let asset = NoteAsset(ownerNoteID: note.id, fileName: "x", mimeType: "image/png", data: Data([1]))
            let extra = NoteAsset(ownerNoteID: existing.id, fileName: "unused", mimeType: "image/png", data: Data([2]))
            let result = try store.importNotebook(NotebookSnapshot(folders: [folder, child], notes: [existing, note], assets: [asset, extra]))
            #expect(result.folders == 0 && result.notes == 0 && result.assets == 0)
            #expect(result.skipped == 6 && !result.warnings.isEmpty)
            #expect(try store.noteFolders().isEmpty)
            #expect(try store.notes().map(\.id) == [existing.id])
            #expect(try store.noteAssets(noteID: existing.id).isEmpty)
        }
    }
    @Test func conflictingAssetOwnershipRejectsWholeMerge() throws {
        try fixture { store, _ in
            let local = try store.saveNote(NoteDocument())
            let asset = NoteAsset(ownerNoteID: local.id, fileName: "x", mimeType: "image/png", data: Data([1]))
            try store.saveNoteAsset(asset)
            let incoming = NoteDocument()
            var conflict = asset; conflict.ownerNoteID = incoming.id
            #expect(throws: (any Error).self) { try store.importNotebook(NotebookSnapshot(notes: [incoming], assets: [conflict])) }
            #expect(try store.notes().map(\.id) == [local.id])
        }
    }
    @Test func failedSQLImportRollsBackAllRowsAndWholeBackup() throws {
        try fixture { store, root in
            let url = root.appendingPathComponent("journal.sqlite")
            _ = try sql(url, "CREATE TRIGGER reject_notes BEFORE INSERT ON notes BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
            let folder = NoteFolder(name: "Must roll back")
            let note = NoteDocument(folderID: folder.id)
            #expect(throws: (any Error).self) { try store.importNotebook(NotebookSnapshot(folders: [folder], notes: [note])) }
            #expect(try store.notebookSnapshot() == NotebookSnapshot())
            let entry = Entry(text: "Must roll back", day: "2026-11-11")
            let incoming = try JournalStore(url: root.appendingPathComponent("incoming.sqlite"))
            try incoming.save(entry); try incoming.saveNoteFolder(folder); _ = try incoming.saveNote(note)
            let backup = try incoming.exportBackup()
            #expect(throws: (any Error).self) { try store.importBackup(backup) }
            #expect(try store.entries().isEmpty)
            #expect(try store.noteFolders(includeDeleted: true).isEmpty)
        }
    }
    @Test func titleBodyAndBatchCountLimitsRejectBeforeWriting() throws {
        try fixture { store, _ in
            #expect(throws: (any Error).self) { try store.saveNoteFolder(NoteFolder(name: String(repeating: "目", count: 121))) }
            #expect(throws: (any Error).self) { try store.saveNote(NoteDocument(title: String(repeating: "题", count: 501))) }
            #expect(throws: (any Error).self) { try store.saveNote(NoteDocument(markdown: String(repeating: "x", count: NotebookValidation.maximumNoteBytes + 1))) }
            #expect(throws: (any Error).self) { try store.importNotebook(NotebookSnapshot(notes: (0...NotebookValidation.maximumImportedNotes).map { NoteDocument(title: "Synthetic \($0)") })) }
            let snapshot = try store.notebookSnapshot()
            #expect(snapshot == NotebookSnapshot())
        }
    }
    @Test func restoringChildBatchMovesToRootWithoutRevivingDeletedParent() throws {
        try fixture { store, _ in
            let root = NoteFolder(name: "Root"); let child = NoteFolder(parentID: root.id, name: "Child")
            try store.saveNoteFolder(root); try store.saveNoteFolder(child)
            let note = try store.saveNote(NoteDocument(folderID: child.id))
            try store.deleteNoteFolder(id: root.id); try store.restoreNoteFolder(id: child.id)
            #expect(try store.noteFolders().first?.id == child.id)
            #expect(try store.noteFolders().first?.parentID == nil)
            #expect(try store.notes().first?.id == note.id)
            #expect(try store.noteFolders(includeDeleted: true).first(where: { $0.id == root.id })?.deletedAt != nil)
        }
    }
    @Test func saveUpdatesModificationTimeAndRejectsMalformedResourceScheme() throws {
        try fixture { store, _ in
            let old = Date(timeIntervalSince1970: 1)
            var folder = NoteFolder(name: "Old", createdAt: old, updatedAt: old)
            try store.saveNoteFolder(folder); folder.name = "Edited"; try store.saveNoteFolder(folder)
            #expect(try store.noteFolders().first!.updatedAt > old)
            let initial = try store.saveNote(NoteDocument(title: "Old", createdAt: old, updatedAt: old))
            var modified = initial; modified.title = "Edited"
            let saved = try store.saveNote(modified, expectedRevision: initial.revision)
            #expect(saved.updatedAt > old)
            var malformed = saved; malformed.markdown = "![invalid](workjournal-asset:broken)"
            #expect(throws: (any Error).self) { try store.saveNote(malformed, expectedRevision: saved.revision) }
        }
    }
    @Test func normalRefreshAndTextSaveNeverReadAssetBlobColumn() throws {
        try fixture { store, root in
            let initial = try store.saveNote(NoteDocument())
            try store.saveNoteAsset(NoteAsset(ownerNoteID: initial.id, data: Data([1])))
            let url = root.appendingPathComponent("journal.sqlite")
            _ = try sql(url, "ALTER TABLE note_assets RENAME TO fixture_assets")
            // The computed data column throws if SQLite evaluates it; metadata queries remain valid.
            _ = try sql(url, "CREATE VIEW note_assets AS SELECT id,owner_note_id,payload,json_extract('invalid JSON','$') AS data FROM fixture_assets")
            #expect(try store.notes().count == 1)
            #expect(try store.noteFolders().isEmpty)
            var modified = initial; modified.markdown = "Text-only change"
            _ = try store.saveNote(modified, expectedRevision: initial.revision)
            #expect(throws: (any Error).self) { try store.noteAssets(noteID: initial.id) }
        }
    }
    @Test func schemaFailureRollsBackAllNewTablesAndKeepsOldVersion() throws {
        try fixture { _, root in
            let url = root.appendingPathComponent("journal.sqlite")
            for table in ["note_assets", "notes", "note_folders"] { _ = try sql(url, "DROP TABLE \(table)") }
            _ = try sql(url, "PRAGMA user_version=4")
            // A preexisting index with the same name forces a real failure after table creation.
            _ = try sql(url, "CREATE INDEX note_assets_owner ON entries(id)")
            #expect(throws: (any Error).self) { try JournalStore(url: url) }
            #expect(try sql(url, "PRAGMA user_version") == 4)
            #expect(try sql(url, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('note_folders','notes','note_assets')") == 0)
        }
    }
    @Test func aggregateImportBytesRejectLargeSharedTextBatch() throws {
        try fixture { store, _ in
            let text = String(repeating: "x", count: NotebookValidation.maximumNoteBytes)
            let noteCount = NotebookValidation.maximumBatchBytes / NotebookValidation.maximumNoteBytes + 1
            let notes = (0..<noteCount).map { NoteDocument(title: "Synthetic \($0)", markdown: text) }
            #expect(throws: (any Error).self) { try store.importNotebook(NotebookSnapshot(notes: notes)) }
            let snapshot = try store.notebookSnapshot()
            #expect(snapshot == NotebookSnapshot())
        }
    }
    @Test func completeBackupRoundTripsLibraryLargerThanSingleTransferBatch() throws {
        try fixture { source, root in
            _ = try source.importNotebook(NotebookSnapshot(notes: (0..<NotebookValidation.maximumImportedNotes).map { NoteDocument(title: "Synthetic \($0)") }))
            _ = try source.saveNote(NoteDocument(title: "Another valid note"), expectedRevision: 0)
            let data = try source.exportBackup()
            let target = try JournalStore(url: root.appendingPathComponent("restored.sqlite"))
            let result = try target.importBackup(data)
            #expect(result.notebook.notes == NotebookValidation.maximumImportedNotes + 1)
            #expect(try target.notes().count == source.notes().count)
        }
    }
    @Test func completeBackupRestoresMoreAssetsThanOneTransferAllows() throws {
        try fixture { source, root in
            let note = NoteDocument(title: "Assets accumulated over time")
            let assets = (0..<NotebookValidation.maximumImportedAssets).map { NoteAsset(ownerNoteID: note.id, fileName: "Synthetic \($0)", data: Data([1])) }
            _ = try source.importNotebook(NotebookSnapshot(notes: [note], assets: assets))
            try source.saveNoteAsset(NoteAsset(ownerNoteID: note.id, data: Data([2])))
            let target = try JournalStore(url: root.appendingPathComponent("restored.sqlite"))
            let result = try target.importBackup(source.exportBackup())
            #expect(result.notebook.assets == NotebookValidation.maximumImportedAssets + 1)
            #expect(try target.noteAssets(noteID: note.id).count == NotebookValidation.maximumImportedAssets + 1)
        }
    }
    @Test func fullLibraryValidationRetainsItemRulesWithoutTransferAggregateCap() throws {
        let text = String(repeating: "x", count: NotebookValidation.maximumNoteBytes)
        let count = NotebookValidation.maximumBatchBytes / NotebookValidation.maximumNoteBytes + 1
        let snapshot = NotebookSnapshot(notes: (0..<count).map { NoteDocument(title: "Synthetic \($0)", markdown: text) })
        #expect(throws: (any Error).self) { try NotebookValidation.validate(snapshot) }
        try NotebookValidation.validateStoredSnapshot(snapshot)
        let oversized = NotebookSnapshot(notes: [NoteDocument(markdown: text + "x")])
        #expect(throws: (any Error).self) { try NotebookValidation.validateStoredSnapshot(oversized) }
        let orphan = NotebookSnapshot(notes: [NoteDocument(folderID: UUID())])
        #expect(throws: (any Error).self) { try NotebookValidation.validateStoredSnapshot(orphan) }
    }
    @Test func repeatedTransferUsesFingerprintsAndReusesExistingFolderPaths() throws {
        try fixture { store, _ in
            let root = NoteFolder(name: "Export"); let child = NoteFolder(parentID: root.id, name: "Child")
            let original = NoteDocument(folderID: child.id, title: "Original", sourceFingerprint: "stable-content")
            let asset = NoteAsset(ownerNoteID: original.id, fileName: "x.png", mimeType: "image/png", kind: .image, data: Data([1]))
            var referenced = original; referenced.markdown = "![](\(asset.reference))"
            _ = try store.importNotebook(NotebookSnapshot(folders: [root, child], notes: [referenced], assets: [asset]))
            try store.deleteNote(id: original.id)
            let freshRoot = NoteFolder(name: "Export"); let freshChild = NoteFolder(parentID: freshRoot.id, name: "Child")
            var repeated = referenced; repeated.id = UUID(); repeated.folderID = freshChild.id
            var freshAsset = asset; freshAsset.id = UUID(); freshAsset.ownerNoteID = repeated.id
            repeated.markdown = "![](\(freshAsset.reference))"
            let result = try store.importNotebook(NotebookSnapshot(folders: [freshRoot, freshChild], notes: [repeated], assets: [freshAsset]))
            #expect(result.folders == 0 && result.notes == 0 && result.assets == 0)
            #expect(result.skipped == 4 && !result.warnings.isEmpty)
            #expect(try store.noteFolders().count == 2)
            #expect(try store.notes(includeDeleted: true).map(\.id) == [original.id])
            #expect(try store.noteAsset(id: freshAsset.id) == nil)
            let newNote = NoteDocument(folderID: freshChild.id, title: "New", sourceFingerprint: "new-content")
            let added = try store.importNotebook(NotebookSnapshot(folders: [freshRoot, freshChild], notes: [repeated, newNote], assets: [freshAsset]))
            #expect(added.folders == 0 && added.notes == 1 && added.assets == 0)
            #expect(try store.notes().first?.folderID == child.id)
        }
    }
    @Test func fingerprintSkippedBranchesDoNotLeaveNewEmptyDirectories() throws {
        try fixture { store, _ in
            _ = try store.saveNote(NoteDocument(title: "Local", sourceFingerprint: "same"))
            let root = NoteFolder(name: "Other export"); let child = NoteFolder(parentID: root.id, name: "Only duplicate")
            let empty = NoteFolder(name: "Intentional empty folder")
            let duplicate = NoteDocument(folderID: child.id, sourceFingerprint: "same")
            let result = try store.importNotebook(NotebookSnapshot(folders: [root, child, empty], notes: [duplicate]))
            #expect(result.folders == 1 && result.notes == 0)
            #expect(try store.noteFolders().map(\.id) == [empty.id])
        }
    }
    @Test func notebookPathReusePreservesDeletedFolderLocalWins() throws {
        try fixture { store, _ in
            let deleted = NoteFolder(name: "Export"); try store.saveNoteFolder(deleted); try store.deleteNoteFolder(id: deleted.id)
            let incoming = NoteFolder(name: "Export")
            let note = NoteDocument(folderID: incoming.id, sourceFingerprint: "new")
            let result = try store.importNotebook(NotebookSnapshot(folders: [incoming], notes: [note]))
            #expect(result.folders == 0 && result.notes == 0)
            #expect(try store.noteFolders().isEmpty)
            #expect(try store.notes(includeDeleted: true).isEmpty)
        }
    }
    @Test func fullBackupKeepsDifferentNoteIDsWithSameFingerprint() throws {
        try fixture { source, root in
            let first = try source.saveNote(NoteDocument(title: "First", sourceFingerprint: "same"))
            let second = try source.saveNote(NoteDocument(title: "Second", sourceFingerprint: "same"))
            let target = try JournalStore(url: root.appendingPathComponent("restored.sqlite"))
            _ = try target.saveNote(first)
            let result = try target.importBackup(source.exportBackup())
            #expect(result.notebook.notes == 1)
            #expect(Set(try target.notes().map(\.id)) == Set([first.id, second.id]))
        }
    }
    @Test func notebookImportCancellationBeforeAndDuringWritesRollsBack() throws {
        try fixture { store, _ in
            let folder = NoteFolder(name: "Cancelled branch")
            let note = NoteDocument(folderID: folder.id)
            let snapshot = NotebookSnapshot(folders: [folder], notes: [note])
            #expect(throws: CancellationError.self) { try store.importNotebook(snapshot, cancelled: { true }) }
            let state1 = try store.notebookSnapshot()
            #expect(state1 == NotebookSnapshot())
            var observedPartialWrite = false
            #expect(throws: CancellationError.self) {
                try store.importNotebook(snapshot, cancelled: {
                    if (try? store.noteFolders(includeDeleted: true).contains(where: { $0.id == folder.id })) == true { observedPartialWrite = true; return true }
                    return false
                })
            }
            #expect(observedPartialWrite)
            let state2 = try store.notebookSnapshot()
            #expect(state2 == NotebookSnapshot())
        }
    }
    @Test func notebookImportChecksCancellationAfterLastAssetBeforeCommit() throws {
        try fixture { store, _ in
            let note = NoteDocument(); let asset = NoteAsset(ownerNoteID: note.id, data: Data([1]))
            var observedLastWrite = false
            #expect(throws: CancellationError.self) {
                try store.importNotebook(NotebookSnapshot(notes: [note], assets: [asset]), cancelled: {
                    if (try? store.noteAsset(id: asset.id)) != nil { observedLastWrite = true; return true }
                    return false
                })
            }
            #expect(observedLastWrite)
            let state3 = try store.notebookSnapshot()
            #expect(state3 == NotebookSnapshot())
        }
    }
    @Test func fingerprintSkippedNoteLinksResolveToRetainedLocalNote() throws {
        try fixture { store, _ in
            let retainedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let retained = try store.saveNote(NoteDocument(id: retainedID, title: "Local B", sourceFingerprint: "same-B"))
            _ = try store.saveNote(NoteDocument(title: "Another B copy", sourceFingerprint: "same-B"))
            try store.deleteNote(id: retained.id)
            let incomingB = NoteDocument(title: "Fresh B", sourceFingerprint: "same-B")
            let incomingA = NoteDocument(title: "Changed A", markdown: "[B](workjournal-note://\(incomingB.id.uuidString.lowercased())) and [anchor](workjournal-note://\(incomingB.id.uuidString.uppercased())#section)", sourceFingerprint: "changed-A")
            let result = try store.importNotebook(NotebookSnapshot(notes: [incomingA, incomingB]))
            #expect(result.notes == 1)
            let storedA = try #require(store.notes().first(where: { $0.id == incomingA.id }))
            #expect(storedA.markdown == "[B](workjournal-note://\(retained.id.uuidString.lowercased())) and [anchor](workjournal-note://\(retained.id.uuidString.lowercased())#section)")
            #expect(try !store.notes(includeDeleted: true).contains(where: { $0.id == incomingB.id }))
        }
    }
    @Test func selectedNotebookSnapshotUsesOneConsistentReadTransaction() throws {
        try fixture { store, root in
            let folder = NoteFolder(name: "Root"); try store.saveNoteFolder(folder)
            let note = try store.saveNote(NoteDocument(folderID: folder.id, markdown: "Before"))
            let asset = NoteAsset(ownerNoteID: note.id, data: Data([1])); try store.saveNoteAsset(asset)
            let url = root.appendingPathComponent("journal.sqlite")
            _ = try sql(url, "PRAGMA journal_mode=WAL")
            var newer = note; newer.markdown = "After"
            let json = String(decoding: try JSONEncoder().encode(newer), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            var changedDuringRead = false
            let snapshot = try store.selectedNotebookSnapshot(noteIDs: [note.id], folderIDs: [folder.id], cancelled: {
                guard !changedDuringRead else { return false }
                let reading = try? store.withStatement("SELECT 1") { statement in sqlite3_txn_state(sqlite3_db_handle(statement), "main") == SQLITE_TXN_READ }
                if reading == true {
                    _ = try? sql(url, "UPDATE notes SET payload='\(json)' WHERE id='\(note.id.uuidString)'")
                    _ = try? sql(url, "UPDATE note_assets SET data=X'09' WHERE id='\(asset.id.uuidString)'")
                    changedDuringRead = true
                }
                return false
            })
            #expect(changedDuringRead)
            #expect(snapshot.notes == [note])
            #expect(snapshot.assets == [asset])
            #expect(try store.notes().first?.markdown == "After")
            #expect(try store.noteAsset(id: asset.id)?.data == Data([9]))
        }
    }
    private func asyncFixture(_ body: (JournalStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-worker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await body(JournalStore(url: root.appendingPathComponent("journal.sqlite")), root)
    }
    @Test @MainActor func databaseWorkerOpensLazilyAndPropagatesTaskCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-worker-lazy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        let worker = NotebookDatabaseWorker(url: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.importNotebook(NotebookSnapshot(notes: [NoteDocument()]))
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let note = NoteDocument(title: "Worker note")
        let result = try await worker.importNotebook(NotebookSnapshot(notes: [note]))
        #expect(result.notes == 1)
        let snapshot = try await worker.snapshot(noteIDs: [note.id], folderIDs: [])
        #expect(snapshot.notes.map(\.id) == [note.id])
    }
    @Test func selectedSnapshotDoesNotDecodeUnselectedNoteBodiesAndCancelsReadTransaction() throws {
        try fixture { store, root in
            let selected = try store.saveNote(NoteDocument(title: "Selected")); let other = try store.saveNote(NoteDocument(title: "Unselected"))
            let url = root.appendingPathComponent("journal.sqlite")
            _ = try sql(url, "ALTER TABLE notes RENAME TO fixture_notes")
            _ = try sql(url, "CREATE VIEW notes AS SELECT id,CASE WHEN id='\(other.id.uuidString)' THEN 'invalid JSON' ELSE payload END AS payload FROM fixture_notes")
            let snapshot = try store.selectedNotebookSnapshot(noteIDs: [selected.id], folderIDs: [])
            #expect(snapshot.notes == [selected])
            var observedRead = false
            #expect(throws: CancellationError.self) {
                try store.selectedNotebookSnapshot(noteIDs: [selected.id], folderIDs: [], cancelled: {
                    let reading = try? store.withStatement("SELECT 1") { statement in sqlite3_txn_state(sqlite3_db_handle(statement), "main") == SQLITE_TXN_READ }
                    if reading == true { observedRead = true; return true }
                    return false
                })
            }
            #expect(observedRead)
            _ = try sql(url, "DROP VIEW notes"); _ = try sql(url, "ALTER TABLE fixture_notes RENAME TO notes")
            _ = try store.saveNote(NoteDocument(title: "Connection still usable after rollback"))
        }
    }
    @Test func databaseWorkerReadsOnlySelectedAssetBlobsAndIncludesFolderAncestors() async throws {
        try await asyncFixture { store, root in
            let folder = NoteFolder(name: "Root"); let child = NoteFolder(parentID: folder.id, name: "Child")
            try store.saveNoteFolder(folder); try store.saveNoteFolder(child)
            let selected = try store.saveNote(NoteDocument(folderID: child.id)); let excluded = try store.saveNote(NoteDocument())
            let wanted = NoteAsset(ownerNoteID: selected.id, data: Data([1,2,3])); let unwanted = NoteAsset(ownerNoteID: excluded.id, data: Data([9]))
            try store.saveNoteAsset(wanted); try store.saveNoteAsset(unwanted)
            let url = root.appendingPathComponent("journal.sqlite")
            _ = try sql(url, "ALTER TABLE note_assets RENAME TO fixture_assets")
            _ = try sql(url, "CREATE VIEW note_assets AS SELECT id,owner_note_id,payload,CASE WHEN owner_note_id='\(excluded.id.uuidString)' THEN json_extract('invalid JSON','$') ELSE data END AS data FROM fixture_assets")
            let worker = NotebookDatabaseWorker(url: url)
            let snapshot = try await worker.snapshot(noteIDs: [selected.id], folderIDs: [child.id])
            #expect(snapshot.notes.map(\.id) == [selected.id])
            #expect(Set(snapshot.folders.map(\.id)) == Set([folder.id, child.id]))
            #expect(snapshot.assets == [wanted])
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await worker.snapshot(noteIDs: [selected.id], folderIDs: [])
            }
            do { _ = try await cancelled.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        }
    }
    @Test func versionFourUpgradeKeepsSnapshotAndExistingContent() throws {
        try fixture { store, root in
            let entry = Entry(text: "Synthetic legacy", day: "2026-11-11"); try store.save(entry)
            let url = root.appendingPathComponent("journal.sqlite")
            _ = try sql(url, "DROP TABLE note_assets"); _ = try sql(url, "DROP TABLE notes"); _ = try sql(url, "DROP TABLE note_folders")
            _ = try sql(url, "PRAGMA user_version=4")
            let migrated = try JournalStore(url: url)
            #expect(try sql(url, "PRAGMA user_version") == 5)
            let backup = try #require(migrated.migrationBackupURL)
            #expect(try sql(backup, "PRAGMA user_version") == 4)
            #expect(try migrated.entries() == [entry])
            #expect(try migrated.notebookSnapshot() == NotebookSnapshot())
        }
    }
}
