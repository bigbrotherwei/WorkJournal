import Foundation
import CSQLite

extension JournalStore {
    public func noteHistory(noteID: UUID) throws -> [NoteVersion] {
        try withStatement("SELECT payload FROM note_history WHERE note_id=? ORDER BY saved_at DESC,id DESC") { statement in
            let status = noteID.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard status == SQLITE_OK else { throw failure() }
            var versions: [NoteVersion] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return versions }
                guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw failure() }
                versions.append(try JSONDecoder().decode(NoteVersion.self, from: Data(String(cString: text).utf8)))
            }
        }
    }
    @discardableResult public func checkpointNote(id: UUID, now: Date = Date()) throws -> NoteVersion {
        try transaction {
            guard let note = try notes().first(where: { $0.id == id }) else { throw JournalError.invalid("笔记不存在或已删除。") }
            return try captureNoteVersion(note, reason: .manual, now: now)
        }
    }
    @discardableResult public func restoreNoteVersion(noteID: UUID, versionID: UUID, expectedRevision: Int, now: Date = Date()) throws -> NoteDocument {
        try transaction {
            guard var note = try notes().first(where: { $0.id == noteID }) else { throw JournalError.invalid("笔记不存在或已删除。") }
            guard note.revision == expectedRevision else { throw JournalError.invalid("笔记已被其他编辑更新，请保留草稿并重新载入。") }
            guard let version = try noteHistory(noteID: noteID).first(where: { $0.id == versionID }) else { throw JournalError.invalid("所选历史版本已不存在。") }
            guard note.revision < Int.max else { throw JournalError.invalid("笔记修订号已达到上限。") }
            _ = try captureNoteVersion(note, reason: .beforeRestore, now: now)
            note.title = version.title; note.markdown = version.markdown; note.updatedAt = now; note.revision += 1
            try NotebookValidation.validateGraph(folders: try noteFolders(includeDeleted: true), notes: try notes(includeDeleted: true).map { $0.id == note.id ? note : $0 }, assets: try read("note_assets", as: NoteAsset.self))
            try persistNote(note)
            return note
        }
    }
    func captureAutomaticVersion(_ current: NoteDocument, replacing proposed: NoteDocument, now: Date) throws {
        guard current.title != proposed.title || current.markdown != proposed.markdown else { return }
        if let last = try noteHistory(noteID: current.id).first {
            if last.title == current.title && last.markdown == current.markdown { return }
            if last.reason == .automatic, now.timeIntervalSince(last.savedAt) >= 0,
               now.timeIntervalSince(last.savedAt) < NotebookHistoryPolicy.coalescingInterval { return }
        }
        _ = try captureNoteVersion(current, reason: .automatic, now: now)
    }
    @discardableResult func captureNoteVersion(_ note: NoteDocument, reason: NoteVersionReason, now: Date) throws -> NoteVersion {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw JournalError.invalid("历史版本时间无效。") }
        if let last = try noteHistory(noteID: note.id).first, last.title == note.title, last.markdown == note.markdown, last.reason == reason { return last }
        let version = NoteVersion(noteID: note.id, title: note.title, markdown: note.markdown, savedAt: now, sourceRevision: note.revision, reason: reason)
        try persistNoteVersion(version)
        try pruneNoteHistory(noteID: note.id, preserving: version.id)
        return version
    }
    func persistNoteVersion(_ version: NoteVersion) throws {
        try execute("INSERT INTO note_history(id,note_id,saved_at,payload) VALUES(?,?,?,?)", values: [version.id.uuidString, version.noteID.uuidString, String(version.savedAt.timeIntervalSinceReferenceDate), try payload(version)])
    }
    func pruneNoteHistory(noteID: UUID, preserving protectedID: UUID? = nil) throws {
        let versions = try noteHistory(noteID: noteID)
        guard versions.count > 2 else { return }
        // A clock rollback or imported future dates must never discard the just-written recovery point.
        let protected = Set([versions.last?.id, versions.first?.id, protectedID].compactMap { $0 })
        var retainedCount = protected.count
        var retainedBytes = versions.filter { protected.contains($0.id) }.reduce(0) { $0 + $1.title.utf8.count + $1.markdown.utf8.count }
        for version in versions where !protected.contains(version.id) {
            let bytes = version.title.utf8.count + version.markdown.utf8.count
            if retainedCount < NotebookHistoryPolicy.maximumVersions && retainedBytes + bytes <= NotebookHistoryPolicy.maximumBytes {
                retainedCount += 1; retainedBytes += bytes
            } else { try execute("DELETE FROM note_history WHERE id=?", values: [version.id.uuidString]) }
        }
    }
}
