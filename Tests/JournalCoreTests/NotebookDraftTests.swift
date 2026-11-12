import Foundation
import Testing
@testable import JournalCore

struct NotebookDraftTests {
    @Test func rejectsOldSessionsAndOutOfOrderChanges() {
        let note = UUID(), session = UUID()
        var gate = NotebookEditGate(noteID: note, sessionID: session)
        let acceptance1 = gate.accept(noteID: note, sessionID: session, sequence: 1)
        #expect(acceptance1)
        let acceptance2 = !gate.accept(noteID: note, sessionID: UUID(), sequence: 2)
        #expect(acceptance2)
        let acceptance3 = !gate.accept(noteID: UUID(), sessionID: session, sequence: 2)
        #expect(acceptance3)
        let acceptance4 = !gate.accept(noteID: note, sessionID: session, sequence: 1)
        #expect(acceptance4)
        let acceptance5 = gate.accept(noteID: note, sessionID: session, sequence: 3)
        #expect(acceptance5)
        let acceptance6 = !gate.accept(noteID: note, sessionID: session, sequence: 2)
        #expect(acceptance6)
    }
    @Test func draftSurvivesRestartAndInvalidOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookDraftStore(directory: directory)
        let note = NoteDocument(title: "Saved", markdown: "old", revision: 3)
        var draft = NotebookDraftEnvelope(noteID: note.id, sessionID: UUID(), baseRevision: 3, sequence: 4, title: "New", markdown: "new")
        try store.save(draft)
        #expect(try NotebookDraftStore(directory: directory).load(noteID: note.id) == draft)
        #expect(draft.recovery(against: note) == .restore)
        var newer = note; newer.revision = 4
        #expect(draft.recovery(against: newer) == .conflict)
        newer.title = draft.title; newer.markdown = draft.markdown
        #expect(draft.recovery(against: newer) == .alreadySaved)
        draft.markdown = String(repeating: "a", count: NotebookValidation.maximumNoteBytes + 1)
        #expect(throws: (any Error).self) { try store.save(draft) }
        #expect(try store.load(noteID: note.id)?.markdown == "new")
        try store.remove(noteID: note.id)
        #expect(try store.load(noteID: note.id) == nil)
    }
    @Test func conflictSurvivesEditingAndSavingTheOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookDraftStore(directory: directory)
        let old = NotebookDraftEnvelope(noteID: UUID(), sessionID: UUID(), baseRevision: 1, sequence: 4, title: "Old", markdown: "Recovery content")
        try store.save(old); try store.archiveConflict(old)
        var fresh = old; fresh.sessionID = UUID(); fresh.baseRevision = 2; fresh.markdown = "New content"
        try store.save(fresh); try store.remove(noteID: fresh.noteID)
        let reopened = NotebookDraftStore(directory: directory)
        #expect(try reopened.conflicts() == [old])
        #expect(try reopened.load(noteID: old.noteID) == nil)
        try reopened.removeConflict(old)
        #expect(try reopened.conflicts().isEmpty)
    }
    @Test func mismatchedDraftFileIsNotAcceptedOrDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = UUID()
        let draft = NotebookDraftEnvelope(noteID: UUID(), sessionID: UUID(), baseRevision: 1, sequence: 1, title: "Synthetic", markdown: "keep")
        let url = directory.appendingPathComponent(expected.uuidString + ".json")
        try JSONEncoder().encode(draft).write(to: url)
        #expect(throws: (any Error).self) { try NotebookDraftStore(directory: directory).load(noteID: expected) }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
