import Foundation

/// Every editor mount has its own session; old WebKit callbacks cannot overwrite another note.
public struct NotebookEditGate: Sendable {
    public let noteID: UUID
    public let sessionID: UUID
    public private(set) var lastSequence: Int = -1
    public init(noteID: UUID, sessionID: UUID) { self.noteID = noteID; self.sessionID = sessionID }
    public mutating func accept(noteID: UUID, sessionID: UUID, sequence: Int) -> Bool {
        guard noteID == self.noteID, sessionID == self.sessionID, sequence >= 0, sequence > lastSequence else { return false }
        lastSequence = sequence; return true
    }
}
public struct NotebookDraftEnvelope: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { sessionID }
    public var noteID: UUID
    public var sessionID: UUID
    public var baseRevision: Int
    public var sequence: Int
    public var title: String
    public var markdown: String
    public var updatedAt: Date
    public init(noteID: UUID, sessionID: UUID, baseRevision: Int, sequence: Int, title: String, markdown: String, updatedAt: Date = Date()) {
        self.noteID = noteID; self.sessionID = sessionID; self.baseRevision = baseRevision; self.sequence = sequence; self.title = title; self.markdown = markdown; self.updatedAt = updatedAt
    }
    public enum Recovery { case restore, alreadySaved, conflict }
    public func recovery(against note: NoteDocument) -> Recovery {
        guard note.id == noteID, note.deletedAt == nil else { return .conflict }
        if note.title == title && note.markdown == markdown { return .alreadySaved }
        return note.revision == baseRevision ? .restore : .conflict
    }
    func validate() throws {
        guard baseRevision >= 0, sequence >= -1, title.count <= NotebookValidation.maximumTitleCharacters,
              !title.contains(where: { $0.isNewline || $0 == "\0" }), markdown.utf8.count <= NotebookValidation.maximumNoteBytes,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else { throw JournalError.invalid("笔记草稿超过大小限制或格式无效。") }
    }
}
/// Per-note atomic journal, retained when SQLite saving fails or a recovery conflicts.
public struct NotebookDraftStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    public func save(_ draft: NotebookDraftEnvelope) throws {
        try draft.validate()
        let data = try JSONEncoder().encode(draft)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(draft.noteID), options: .atomic)
    }
    public func load(noteID: UUID) throws -> NotebookDraftEnvelope? {
        let path = url(noteID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= NotebookValidation.maximumNoteBytes * 6 + 8192 else { throw JournalError.invalid("草稿文件过大，原文件已保留。") }
        let draft = try JSONDecoder().decode(NotebookDraftEnvelope.self, from: Data(contentsOf: path))
        guard draft.noteID == noteID else { throw JournalError.invalid("草稿与文件标识不匹配，原文件已保留。") }
        try draft.validate(); return draft
    }
    public func remove(noteID: UUID) throws {
        let path = url(noteID); if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    private var conflictsDirectory: URL { directory.appendingPathComponent("Recovered", isDirectory: true) }
    private func conflictURL(_ draft: NotebookDraftEnvelope) -> URL { conflictsDirectory.appendingPathComponent(draft.noteID.uuidString + "-" + draft.sessionID.uuidString + ".json") }
    public func archiveConflict(_ draft: NotebookDraftEnvelope) throws {
        try draft.validate()
        try FileManager.default.createDirectory(at: conflictsDirectory, withIntermediateDirectories: true)
        let target = conflictURL(draft)
        if !FileManager.default.fileExists(atPath: target.path) { try JSONEncoder().encode(draft).write(to: target, options: .atomic) }
        try remove(noteID: draft.noteID)
    }
    public func conflicts() throws -> [NotebookDraftEnvelope] {
        guard FileManager.default.fileExists(atPath: conflictsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: conflictsDirectory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "json" }.map { path in
            guard (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= NotebookValidation.maximumNoteBytes * 6 + 8192 else { throw JournalError.invalid("恢复草稿过大，文件已保留。") }
            let value = try JSONDecoder().decode(NotebookDraftEnvelope.self, from: Data(contentsOf: path)); try value.validate()
            guard path.lastPathComponent == conflictURL(value).lastPathComponent else { throw JournalError.invalid("恢复草稿标识不符，文件已保留。") }
            return value
        }
    }
    public func removeConflict(_ draft: NotebookDraftEnvelope) throws { try FileManager.default.removeItem(at: conflictURL(draft)) }
    public func noteIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }
}
