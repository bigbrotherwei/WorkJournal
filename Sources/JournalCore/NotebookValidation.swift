import Foundation

/// Storage/import limits, independent of editor preview limits.
public enum NotebookValidation {
    public static let maximumFolderDepth = 16
    public static let maximumNameCharacters = 120
    public static let maximumTitleCharacters = 500
    public static let maximumNoteBytes = 8 * 1024 * 1024
    public static let maximumAssetBytes = 128 * 1024 * 1024
    public static let maximumBatchBytes = 1024 * 1024 * 1024
    public static let maximumImportedNotes = 10_000
    public static let maximumImportedAssets = 20_000

    public static func validate(_ snapshot: NotebookSnapshot, cancelled: () -> Bool = { false }) throws {
        try checkNotebookCancellation(cancelled)
        guard snapshot.notes.count <= maximumImportedNotes, snapshot.assets.count <= maximumImportedAssets else { throw invalid("一次导入最多 10,000 篇笔记和 20,000 个资源。") }
        var total = 0
        for note in snapshot.notes { try checkNotebookCancellation(cancelled); total += note.markdown.utf8.count }
        for asset in snapshot.assets { try checkNotebookCancellation(cancelled); try validateAsset(asset); total += asset.data.count }
        guard total <= maximumBatchBytes else { throw invalid("一次导入的笔记和资源不能超过 1 GiB。") }
        try validateStoredSnapshot(snapshot, cancelled: cancelled)
    }
    /// A complete library may exceed one transfer batch after many valid imports.
    /// Keep every per-item and graph constraint, without transfer count/aggregate caps.
    static func validateStoredSnapshot(_ snapshot: NotebookSnapshot, cancelled: () -> Bool = { false }) throws {
        try validateGraph(folders: snapshot.folders, notes: snapshot.notes, assets: snapshot.assets, cancelled: cancelled)
    }
    static func validateAsset(_ asset: NoteAsset) throws {
        guard asset.data.count <= maximumAssetBytes else { throw invalid("单个资源不能超过 128 MiB。") }
        guard !asset.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              asset.fileName.utf8.count <= 1024, !asset.fileName.contains("\0"),
              !asset.mimeType.isEmpty, asset.mimeType.utf8.count <= 255, !asset.mimeType.contains(where: { $0.isNewline || $0 == "\0" }) else { throw invalid("资源文件名或媒体类型无效。") }
    }
    static func validateGraph(folders: [NoteFolder], notes: [NoteDocument], assets: [NoteAsset], cancelled: () -> Bool = { false }) throws {
        try checkNotebookCancellation(cancelled)
        guard Set(folders.map(\.id)).count == folders.count, Set(notes.map(\.id)).count == notes.count,
              Set(assets.map(\.id)).count == assets.count else { throw invalid("笔记数据包含重复 ID。") }
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for folder in folders {
            try checkNotebookCancellation(cancelled)
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, folder.name.count <= maximumNameCharacters, name != ".", name != "..",
                  !folder.name.contains(where: { $0.isNewline || $0 == "/" || $0 == "\\" || $0 == "\0" }) else { throw invalid("目录名称须为 1～120 字，不能包含路径分隔符或换行。") }
            try dates(created: folder.createdAt, updated: folder.updatedAt, deleted: folder.deletedAt, batch: folder.deletionBatchID)
            var visited: Set<UUID> = [folder.id]; var parent = folder.parentID; var depth = 1
            while let id = parent {
                try checkNotebookCancellation(cancelled)
                guard visited.insert(id).inserted else { throw invalid("目录不能移动至自身或子目录。") }
                guard let ancestor = foldersByID[id] else { throw invalid("笔记目录的父目录不存在。") }
                if folder.deletedAt == nil && ancestor.deletedAt != nil { throw invalid("有效目录不能位于回收站目录内。") }
                depth += 1; guard depth <= maximumFolderDepth else { throw invalid("目录最多支持 16 层。") }; parent = ancestor.parentID
            }
        }
        for note in notes {
            try checkNotebookCancellation(cancelled)
            guard note.title.count <= maximumTitleCharacters, !note.title.contains(where: { $0.isNewline || $0 == "\0" }),
                  note.markdown.utf8.count <= maximumNoteBytes, note.revision >= 0 else { throw invalid("笔记标题、正文大小或修订号无效（标题最多 500 字，正文最多 8 MiB）。") }
            try dates(created: note.createdAt, updated: note.updatedAt, deleted: note.deletedAt, batch: note.deletionBatchID)
            if let id = note.folderID {
                guard let parent = foldersByID[id], note.deletedAt != nil || parent.deletedAt == nil else { throw invalid("笔记所属目录不存在或已删除。") }
            }
            try validateReferences(note, assetsByID: assetsByID, cancelled: cancelled)
        }
        for asset in assets {
            try checkNotebookCancellation(cancelled)
            guard notesByID[asset.ownerNoteID] != nil else { throw invalid("资源所属笔记不存在。") }
            try validateAsset(asset)
        }
    }
    private static func dates(created: Date, updated: Date, deleted: Date?, batch: UUID?) throws {
        guard created.timeIntervalSinceReferenceDate.isFinite, updated.timeIntervalSinceReferenceDate.isFinite,
              deleted?.timeIntervalSinceReferenceDate.isFinite != false, deleted != nil || batch == nil else { throw invalid("笔记日期或删除批次无效。") }
    }
    private static func validateReferences(_ note: NoteDocument, assetsByID: [UUID: NoteAsset], cancelled: () -> Bool) throws {
        let pattern = #"(?i)workjournal-asset:[^\s<>\"'\)\]]*"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = note.markdown as NSString
        for match in regex.matches(in: note.markdown, range: NSRange(location: 0, length: ns.length)) {
            try checkNotebookCancellation(cancelled)
            let raw = ns.substring(with: match.range)
            guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "workjournal-asset",
                  let host = url.host, let ownerID = UUID(uuidString: host), ownerID == note.id,
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.path.split(separator: "/").count == 1,
                  let assetID = UUID(uuidString: String(url.path.dropFirst())), let asset = assetsByID[assetID], asset.ownerNoteID == note.id else { throw invalid("笔记包含无效、缺失或跨笔记的资源引用。") }
        }
    }
    private static func invalid(_ message: String) -> JournalError { .invalid(message) }
}
