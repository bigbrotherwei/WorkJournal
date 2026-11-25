import Foundation

public enum NoteVersionReason: String, Codable, Sendable { case automatic, manual, beforeRestore }

public struct NoteVersion: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var noteID: UUID
    public var title: String
    public var markdown: String
    public var savedAt: Date
    public var sourceRevision: Int
    public var reason: NoteVersionReason
    public init(id: UUID = UUID(), noteID: UUID, title: String, markdown: String, savedAt: Date = Date(), sourceRevision: Int, reason: NoteVersionReason = .automatic) {
        self.id = id; self.noteID = noteID; self.title = title; self.markdown = markdown
        self.savedAt = savedAt; self.sourceRevision = sourceRevision; self.reason = reason
    }
}

public enum NotebookHistoryPolicy {
    public static let coalescingInterval: TimeInterval = 300
    public static let maximumVersions = 100
    public static let maximumBytes = 32 * 1024 * 1024

    static func validate(_ versions: [NoteVersion], notes: [NoteDocument], assets: [NoteAsset]) throws {
        guard Set(versions.map(\.id)).count == versions.count else { throw JournalError.invalid("笔记历史包含重复 ID。") }
        let noteIDs = Set(notes.map(\.id))
        let assetsByOwner = Dictionary(grouping: assets, by: \.ownerNoteID)
        for version in versions {
            guard noteIDs.contains(version.noteID), version.savedAt.timeIntervalSinceReferenceDate.isFinite, version.sourceRevision >= 0 else {
                throw JournalError.invalid("笔记历史所属笔记、日期或修订号无效。")
            }
            let document = NoteDocument(id: version.noteID, title: version.title, markdown: version.markdown, revision: version.sourceRevision)
            try NotebookValidation.validateGraph(folders: [], notes: [document], assets: assetsByOwner[version.noteID] ?? [])
        }
    }
}
