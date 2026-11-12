import Foundation
import CSQLite

extension JournalStore {
    public func noteFolders(includeDeleted: Bool = false) throws -> [NoteFolder] {
        try read("note_folders", as: NoteFolder.self).filter { includeDeleted || $0.deletedAt == nil }
            .sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
    }
    public func notes(includeDeleted: Bool = false) throws -> [NoteDocument] {
        try read("notes", as: NoteDocument.self).filter { includeDeleted || $0.deletedAt == nil }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }
    public func noteAssets(noteID: UUID) throws -> [NoteAsset] {
        try readNoteAssets(whereSQL: " WHERE owner_note_id=?", value: noteID.uuidString)
    }
    public func noteAsset(id: UUID) throws -> NoteAsset? {
        try readNoteAssets(whereSQL: " WHERE id=?", value: id.uuidString).first
    }
    public func notebookSnapshot() throws -> NotebookSnapshot {
        NotebookSnapshot(folders: try noteFolders(includeDeleted: true), notes: try notes(includeDeleted: true), assets: try readNoteAssets())
    }
    /// Reads JSON metadata only. This path never fetches the asset BLOB column.
    private func assetMetadata() throws -> [NoteAsset] { try read("note_assets", as: NoteAsset.self) }
    private func readNoteAssets(whereSQL: String = "", value: String? = nil, cancelled: () -> Bool = { false }) throws -> [NoteAsset] {
        try checkNotebookCancellation(cancelled)
        return try withStatement("SELECT payload,data FROM note_assets\(whereSQL) ORDER BY id") { statement in
            if let value { try bind(value, at: 1, statement: statement) }
            var assets: [NoteAsset] = []
            while true {
                try checkNotebookCancellation(cancelled)
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return assets }
                guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw failure() }
                var asset = try JSONDecoder().decode(NoteAsset.self, from: Data(String(cString: text).utf8))
                let count = Int(sqlite3_column_bytes(statement, 1))
                if count > 0 {
                    guard let bytes = sqlite3_column_blob(statement, 1) else { throw failure() }
                    asset.data = Data(bytes: bytes, count: count)
                }
                assets.append(asset)
            }
        }
    }
    private func bind(_ value: String, at index: Int32, statement: OpaquePointer?) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK else { throw failure() }
    }
    private func persistFolder(_ folder: NoteFolder) throws {
        try execute("INSERT INTO note_folders(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", values: [folder.id.uuidString, try payload(folder)])
    }
    private func persistNote(_ note: NoteDocument) throws {
        try execute("INSERT INTO notes(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", values: [note.id.uuidString, try payload(note)])
    }
    private func persistAsset(_ asset: NoteAsset) throws {
        var metadata = asset; metadata.data = Data()
        try withStatement("INSERT INTO note_assets(id,owner_note_id,payload,data) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,data=excluded.data") { statement in
            try bind(asset.id.uuidString, at: 1, statement: statement)
            try bind(asset.ownerNoteID.uuidString, at: 2, statement: statement)
            try bind(try payload(metadata), at: 3, statement: statement)
            let result: Int32
            if asset.data.isEmpty { result = sqlite3_bind_zeroblob(statement, 4, 0) }
            else { result = asset.data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
            guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }
    public func saveNoteFolder(_ folder: NoteFolder) throws {
        try transaction {
            var folder = folder
            var folders = try noteFolders(includeDeleted: true)
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                guard folders[index].deletedAt == folder.deletedAt, folders[index].deletionBatchID == folder.deletionBatchID else { throw JournalError.invalid("请通过回收站操作删除或恢复目录。") }
                folder.updatedAt = Date()
                folders[index] = folder
            } else { folders.append(folder) }
            try NotebookValidation.validateGraph(folders: folders, notes: try notes(includeDeleted: true), assets: try assetMetadata())
            try persistFolder(folder)
        }
    }
    @discardableResult public func saveNote(_ proposed: NoteDocument, expectedRevision: Int? = nil) throws -> NoteDocument {
        try transaction {
            var allNotes = try notes(includeDeleted: true)
            let current = allNotes.first { $0.id == proposed.id }
            if let expectedRevision, expectedRevision != (current?.revision ?? 0) { throw JournalError.invalid("笔记已被其他编辑更新，请保留草稿并重新载入。") }
            if let current {
                guard current.deletedAt == proposed.deletedAt, current.deletionBatchID == proposed.deletionBatchID else { throw JournalError.invalid("笔记已删除或删除状态已变化，请从回收站恢复。") }
            }
            var note = proposed
            note.updatedAt = Date()
            guard (current?.revision ?? 0) < Int.max else { throw JournalError.invalid("笔记修订号已达到上限。") }
            note.revision = (current?.revision ?? 0) + 1
            allNotes.removeAll { $0.id == note.id }; allNotes.append(note)
            try NotebookValidation.validateGraph(folders: try noteFolders(includeDeleted: true), notes: allNotes, assets: try assetMetadata())
            try persistNote(note)
            return note
        }
    }
    public func saveNoteAsset(_ asset: NoteAsset) throws {
        try transaction {
            try NotebookValidation.validateAsset(asset)
            guard try notes().contains(where: { $0.id == asset.ownerNoteID }) else { throw JournalError.invalid("资源所属笔记不存在或已删除。") }
            var assets = try assetMetadata()
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                guard assets[index].ownerNoteID == asset.ownerNoteID else { throw JournalError.invalid("资源 ID 已属于其他笔记。") }
                assets[index] = asset
            } else { assets.append(asset) }
            try NotebookValidation.validateGraph(folders: try noteFolders(includeDeleted: true), notes: try notes(includeDeleted: true), assets: assets)
            try persistAsset(asset)
        }
    }
    public func deleteNote(id: UUID) throws {
        try transaction {
            guard var note = try notes().first(where: { $0.id == id }) else { return }
            note.deletedAt = Date(); note.updatedAt = Date(); note.deletionBatchID = UUID(); try advanceRevision(&note); try persistNote(note)
        }
    }
    public func deleteNoteFolder(id: UUID) throws {
        try transaction {
            let folders = try noteFolders(includeDeleted: true)
            guard folders.contains(where: { $0.id == id && $0.deletedAt == nil }) else { return }
            let ids = descendantIDs(id: id, folders: folders.filter { $0.deletedAt == nil })
            let batch = UUID(); let now = Date()
            for var folder in folders where ids.contains(folder.id) && folder.deletedAt == nil {
                folder.deletedAt = now; folder.updatedAt = now; folder.deletionBatchID = batch; try persistFolder(folder)
            }
            for var note in try notes() where note.folderID.map(ids.contains) == true {
                note.deletedAt = now; note.updatedAt = now; note.deletionBatchID = batch; try advanceRevision(&note); try persistNote(note)
            }
        }
    }
    public func restoreNote(id: UUID) throws {
        try transaction {
            guard var note = try notes(includeDeleted: true).first(where: { $0.id == id && $0.deletedAt != nil }) else { return }
            if let folderID = note.folderID, try !noteFolders().contains(where: { $0.id == folderID }) { note.folderID = nil }
            note.deletedAt = nil; note.deletionBatchID = nil; note.updatedAt = Date(); try advanceRevision(&note); try persistNote(note)
        }
    }
    public func restoreNoteFolder(id: UUID) throws {
        try transaction {
            var folders = try noteFolders(includeDeleted: true)
            guard let selected = folders.first(where: { $0.id == id && $0.deletedAt != nil }) else { return }
            // A child selected from a batch restores only that branch of the batch.
            let descendants = descendantIDs(id: id, folders: folders)
            let restoreIDs = Set(folders.filter { descendants.contains($0.id) && $0.deletedAt != nil && ($0.id == id || selected.deletionBatchID != nil && $0.deletionBatchID == selected.deletionBatchID) }.map(\.id))
            for index in folders.indices where restoreIDs.contains(folders[index].id) {
                folders[index].deletedAt = nil; folders[index].deletionBatchID = nil; folders[index].updatedAt = Date()
            }
            let liveIDs = Set(folders.filter { $0.deletedAt == nil }.map(\.id))
            for index in folders.indices where restoreIDs.contains(folders[index].id) {
                if let parent = folders[index].parentID, !liveIDs.contains(parent) { folders[index].parentID = nil }
            }
            var allNotes = try notes(includeDeleted: true)
            for index in allNotes.indices where selected.deletionBatchID != nil && allNotes[index].deletionBatchID == selected.deletionBatchID && allNotes[index].folderID.map(restoreIDs.contains) == true {
                allNotes[index].deletedAt = nil; allNotes[index].deletionBatchID = nil; allNotes[index].updatedAt = Date(); try advanceRevision(&allNotes[index])
            }
            try NotebookValidation.validateGraph(folders: folders, notes: allNotes, assets: try assetMetadata())
            for folder in folders where restoreIDs.contains(folder.id) { try persistFolder(folder) }
            for note in allNotes where note.deletedAt == nil && note.folderID.map(restoreIDs.contains) == true { try persistNote(note) }
        }
    }
    public func permanentlyDeleteNote(id: UUID) throws {
        try transaction {
            guard try notes(includeDeleted: true).contains(where: { $0.id == id && $0.deletedAt != nil }) else { throw JournalError.invalid("只能永久删除回收站中的笔记。") }
            try removeNote(id: id)
        }
    }
    public func permanentlyDeleteNoteFolder(id: UUID) throws {
        try transaction {
            let folders = try noteFolders(includeDeleted: true)
            guard folders.contains(where: { $0.id == id && $0.deletedAt != nil }) else { throw JournalError.invalid("只能永久删除回收站中的目录。") }
            let ids = descendantIDs(id: id, folders: folders)
            for note in try notes(includeDeleted: true) where note.folderID.map(ids.contains) == true { try removeNote(id: note.id) }
            for folderID in ids { try execute("DELETE FROM note_folders WHERE id=?", values: [folderID.uuidString]) }
        }
    }
    private func removeNote(id: UUID) throws {
        try execute("DELETE FROM note_assets WHERE owner_note_id=?", values: [id.uuidString])
        try execute("DELETE FROM notes WHERE id=?", values: [id.uuidString])
    }
    private func advanceRevision(_ note: inout NoteDocument) throws {
        guard note.revision < Int.max else { throw JournalError.invalid("笔记修订号已达到上限。") }; note.revision += 1
    }
    private func descendantIDs(id: UUID, folders: [NoteFolder]) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for folder in folders where folder.parentID.map(result.contains) == true {
                if result.insert(folder.id).inserted { changed = true }
            }
        }
        return result
    }
    public func importNotebook(_ snapshot: NotebookSnapshot, cancelled: () -> Bool = { false }) throws -> NotebookImportResult {
        try checkNotebookCancellation(cancelled)
        try NotebookValidation.validate(snapshot, cancelled: cancelled)
        try checkNotebookCancellation(cancelled)
        return try transaction {
            let result = try mergeNotebook(snapshot, deduplicateSource: true, cancelled: cancelled)
            // A late cancellation after the final asset write must still roll back.
            try checkNotebookCancellation(cancelled)
            return result
        }
    }
    /// Called inside the caller's transaction, including full backup imports.
    func mergeNotebook(_ incoming: NotebookSnapshot, deduplicateSource: Bool = false, cancelled: () -> Bool = { false }) throws -> NotebookImportResult {
        try checkNotebookCancellation(cancelled)
        let localFolders = try read("note_folders", as: NoteFolder.self, cancelled: cancelled)
        let localNotes = try read("notes", as: NoteDocument.self, cancelled: cancelled)
        let localAssets = try read("note_assets", as: NoteAsset.self, cancelled: cancelled)
        let folderIDs = Set(localFolders.map(\.id)); let noteIDs = Set(localNotes.map(\.id))
        let localAssetByID = Dictionary(uniqueKeysWithValues: localAssets.map { ($0.id, $0) })
        for asset in incoming.assets {
            try checkNotebookCancellation(cancelled)
            if let local = localAssetByID[asset.id], local.ownerNoteID != asset.ownerNoteID { throw JournalError.invalid("备份资源 ID 与本机所属笔记冲突，未修改数据。") }
        }
        let prepared: NotebookSnapshot
        let duplicateSources: Int
        if deduplicateSource {
            var fingerprintTargets: [String: UUID] = [:]
            // Same-fingerprint legacy copies are resolved deterministically by UUID.
            for note in localNotes {
                try checkNotebookCancellation(cancelled)
                guard let fingerprint = note.sourceFingerprint, !fingerprint.isEmpty else { continue }
                if let previous = fingerprintTargets[fingerprint], previous.uuidString < note.id.uuidString { continue }
                fingerprintTargets[fingerprint] = note.id
            }
            var duplicateMapping: [UUID: UUID] = [:]
            for note in incoming.notes {
                try checkNotebookCancellation(cancelled)
                if let fingerprint = note.sourceFingerprint, let target = fingerprintTargets[fingerprint] { duplicateMapping[note.id] = noteIDs.contains(note.id) ? note.id : target }
            }
            prepared = try prepareSourceMerge(incoming, localFolders: localFolders, localNoteIDs: noteIDs, duplicateMapping: duplicateMapping, cancelled: cancelled)
            duplicateSources = duplicateMapping.count
        } else { prepared = incoming; duplicateSources = 0 }
        var blocked = Set(localFolders.filter { $0.deletedAt != nil }.map(\.id))
        var changed = true
        while changed {
            try checkNotebookCancellation(cancelled)
            changed = false
            for folder in prepared.folders where !folderIDs.contains(folder.id) && folder.parentID.map(blocked.contains) == true {
                try checkNotebookCancellation(cancelled)
                if blocked.insert(folder.id).inserted { changed = true }
            }
        }
        let folders = prepared.folders.filter { !folderIDs.contains($0.id) && !blocked.contains($0.id) }
        let notes = prepared.notes.filter { !noteIDs.contains($0.id) && $0.folderID.map(blocked.contains) != true }
        let addedNoteIDs = Set(notes.map(\.id))
        let assets = prepared.assets.filter { addedNoteIDs.contains($0.ownerNoteID) && localAssetByID[$0.id] == nil }
        try NotebookValidation.validateGraph(folders: localFolders + folders, notes: localNotes + notes, assets: localAssets + assets, cancelled: cancelled)
        for folder in folders { try checkNotebookCancellation(cancelled); try persistFolder(folder) }
        for note in notes { try checkNotebookCancellation(cancelled); try persistNote(note) }
        for asset in assets { try checkNotebookCancellation(cancelled); try persistAsset(asset) }
        try checkNotebookCancellation(cancelled)
        let skipped = incoming.folders.count + incoming.notes.count + incoming.assets.count - folders.count - notes.count - assets.count
        let dependent = prepared.folders.filter { !folderIDs.contains($0.id) && blocked.contains($0.id) }.count + prepared.notes.filter { !noteIDs.contains($0.id) && $0.folderID.map(blocked.contains) == true }.count
        var warnings: [String] = []
        if skipped > 0 { warnings.append("保留本机已有内容，跳过 \(skipped) 个已有或依赖不可用目录的对象。") }
        if duplicateSources > 0 { warnings.append("有 \(duplicateSources) 篇笔记的来源内容已存在（包括回收站），已跳过笔记及其资源。") }
        if dependent > 0 { warnings.append("有 \(dependent) 个新增目录或笔记依赖本机已删除目录，已跳过整个分支。") }
        return NotebookImportResult(folders: folders.count, notes: notes.count, assets: assets.count, skipped: skipped, warnings: warnings)
    }
    /// Reuse only unambiguous local paths. Note/asset identities remain unchanged;
    /// links targeting a fingerprint-skipped note are redirected to the retained ID.
    private func prepareSourceMerge(_ incoming: NotebookSnapshot, localFolders: [NoteFolder], localNoteIDs: Set<UUID>, duplicateMapping: [UUID: UUID], cancelled: () -> Bool) throws -> NotebookSnapshot {
        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.folders.map { ($0.id, $0) })
        let localIDs = Set(localFolders.map(\.id))
        var mapping: [UUID: UUID] = [:]
        func mappedFolder(_ id: UUID) throws -> UUID {
            try checkNotebookCancellation(cancelled)
            if let mapped = mapping[id] { return mapped }
            guard !localIDs.contains(id), let folder = incomingByID[id] else { mapping[id] = id; return id }
            let mappedParent = try folder.parentID.map(mappedFolder)
            let matches = localFolders.filter { $0.parentID == mappedParent && $0.name == folder.name }
            let mapped = matches.count == 1 ? matches[0].id : id
            mapping[id] = mapped
            return mapped
        }
        for folder in incoming.folders { _ = try mappedFolder(folder.id) }
        func ancestors(of start: UUID) throws -> Set<UUID> {
            var ids: Set<UUID> = []; var cursor: UUID? = start
            while let id = cursor, ids.insert(id).inserted { try checkNotebookCancellation(cancelled); cursor = incomingByID[id]?.parentID }
            return ids
        }
        var originallyOccupied: Set<UUID> = []
        for note in incoming.notes { try checkNotebookCancellation(cancelled); if let folder = note.folderID { originallyOccupied.formUnion(try ancestors(of: folder)) } }
        let keptNotes = incoming.notes.filter { duplicateMapping[$0.id] == nil }
        var required: Set<UUID> = []
        for note in keptNotes where !localNoteIDs.contains(note.id) {
            try checkNotebookCancellation(cancelled)
            if let folder = note.folderID { required.formUnion(try ancestors(of: folder)) }
        }
        // Explicitly empty source folders (and their ancestors) remain meaningful.
        for folder in incoming.folders where !originallyOccupied.contains(folder.id) { required.formUnion(try ancestors(of: folder.id)) }
        let folders = incoming.folders.filter { required.contains($0.id) && mapping[$0.id] == $0.id }.map { original in
            var folder = original; folder.parentID = folder.parentID.map { mapping[$0] ?? $0 }; return folder
        }
        let linkPattern = #"(?i)workjournal-note://([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f-])"#
        let links = try NSRegularExpression(pattern: linkPattern)
        var notes: [NoteDocument] = []
        for var note in keptNotes {
            try checkNotebookCancellation(cancelled)
            note.folderID = note.folderID.map { mapping[$0] ?? $0 }
            let text = note.markdown as NSString
            for match in links.matches(in: note.markdown, range: NSRange(location: 0, length: text.length)).reversed() {
                try checkNotebookCancellation(cancelled)
                guard let id = UUID(uuidString: text.substring(with: match.range(at: 1))), let retained = duplicateMapping[id], let range = Range(match.range(at: 1), in: note.markdown) else { continue }
                note.markdown.replaceSubrange(range, with: retained.uuidString.lowercased())
            }
            notes.append(note)
        }
        let keptNoteIDs = Set(keptNotes.map(\.id))
        return NotebookSnapshot(folders: folders, notes: notes, assets: incoming.assets.filter { keptNoteIDs.contains($0.ownerNoteID) })
    }

    private func selectedNoteRows(ids: Set<UUID>, cancelled: () -> Bool) throws -> [NoteDocument] {
        try checkNotebookCancellation(cancelled)
        return try withStatement("SELECT payload FROM notes WHERE id=?") { statement in
            var result: [NoteDocument] = []
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                try checkNotebookCancellation(cancelled)
                guard sqlite3_reset(statement) == SQLITE_OK, sqlite3_clear_bindings(statement) == SQLITE_OK else { throw failure() }
                try bind(id.uuidString, at: 1, statement: statement)
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { continue }
                guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw failure() }
                let note = try JSONDecoder().decode(NoteDocument.self, from: Data(String(cString: text).utf8))
                guard note.id == id else { throw JournalError.invalid("笔记标识与存储内容不一致。") }
                if note.deletedAt == nil { result.append(note) }
            }
            try checkNotebookCancellation(cancelled)
            return result
        }
    }

    /// Consistent export selection: metadata first, then only selected owners' BLOBs.
    /// Folder IDs are explicit; required ancestors of folders/notes are included.
    func selectedNotebookSnapshot(noteIDs: Set<UUID>, folderIDs: Set<UUID>, cancelled: () -> Bool = { false }) throws -> NotebookSnapshot {
        try checkNotebookCancellation(cancelled)
        return try transaction(beginSQL: "BEGIN DEFERRED") {
            let allFolders = try read("note_folders", as: NoteFolder.self, cancelled: cancelled)
            let selected = try selectedNoteRows(ids: noteIDs, cancelled: cancelled)
            let liveFolders = allFolders.filter { $0.deletedAt == nil }
            let byID = Dictionary(uniqueKeysWithValues: liveFolders.map { ($0.id, $0) })
            guard selected.count == noteIDs.count, folderIDs.isSubset(of: Set(byID.keys)) else { throw JournalError.invalid("导出范围已变化，请重新选择笔记或目录。") }
            var needed = folderIDs.union(selected.compactMap(\.folderID))
            var pending = Array(needed)
            while let id = pending.popLast() {
                try checkNotebookCancellation(cancelled)
                guard let folder = byID[id] else { throw JournalError.invalid("笔记所属目录不存在或已删除。") }
                if let parent = folder.parentID, needed.insert(parent).inserted { pending.append(parent) }
            }
            var assets: [NoteAsset] = []
            for note in selected {
                try checkNotebookCancellation(cancelled)
                assets.append(contentsOf: try readNoteAssets(whereSQL: " WHERE owner_note_id=?", value: note.id.uuidString, cancelled: cancelled))
            }
            try checkNotebookCancellation(cancelled)
            return NotebookSnapshot(folders: liveFolders.filter { needed.contains($0.id) }, notes: selected, assets: assets)
        }
    }
}
