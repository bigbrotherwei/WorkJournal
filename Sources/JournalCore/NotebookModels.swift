import Foundation

public struct NoteFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var parentID: UUID?
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deletionBatchID: UUID?
    public init(id: UUID = UUID(), parentID: UUID? = nil, name: String = "新建笔记本", createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil, deletionBatchID: UUID? = nil) {
        self.id = id; self.parentID = parentID; self.name = name; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt; self.deletionBatchID = deletionBatchID
    }
}

public struct NoteDocument: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var folderID: UUID?
    public var title: String
    public var markdown: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deletionBatchID: UUID?
    public var revision: Int
    public var tags: [String]
    public var source: String?
    public var sourceFingerprint: String?
    public init(id: UUID = UUID(), folderID: UUID? = nil, title: String = "未命名笔记", markdown: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil, deletionBatchID: UUID? = nil, revision: Int = 0, tags: [String] = [], source: String? = nil, sourceFingerprint: String? = nil) {
        self.id = id; self.folderID = folderID; self.title = title; self.markdown = markdown; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt; self.deletionBatchID = deletionBatchID; self.revision = revision; self.tags = tags; self.source = source; self.sourceFingerprint = sourceFingerprint
    }
}

public enum NoteAssetKind: String, Codable, Equatable, Sendable { case image, pdf, attachment }

public struct NoteAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var ownerNoteID: UUID
    public var fileName: String
    public var mimeType: String
    public var kind: NoteAssetKind
    public var data: Data
    public var reference: String { "workjournal-asset://\(ownerNoteID.uuidString.lowercased())/\(id.uuidString.lowercased())" }
    public init(id: UUID = UUID(), ownerNoteID: UUID, fileName: String = "attachment", mimeType: String = "application/octet-stream", kind: NoteAssetKind = .attachment, data: Data = Data()) {
        self.id = id; self.ownerNoteID = ownerNoteID; self.fileName = fileName; self.mimeType = mimeType; self.kind = kind; self.data = data
    }
}

public struct NotebookSnapshot: Codable, Equatable, Sendable {
    public var folders: [NoteFolder]
    public var notes: [NoteDocument]
    public var assets: [NoteAsset]
    public init(folders: [NoteFolder] = [], notes: [NoteDocument] = [], assets: [NoteAsset] = []) { self.folders = folders; self.notes = notes; self.assets = assets }
}

public struct NotebookImportResult: Codable, Equatable, Sendable {
    public var folders: Int
    public var notes: Int
    public var assets: Int
    public var skipped: Int
    public var warnings: [String]
    public init(folders: Int = 0, notes: Int = 0, assets: Int = 0, skipped: Int = 0, warnings: [String] = []) { self.folders = folders; self.notes = notes; self.assets = assets; self.skipped = skipped; self.warnings = warnings }
}
