import AppKit
import SwiftUI
import JournalCore

@MainActor final class NotebookModel: ObservableObject {
    @Published private(set) var folders: [NoteFolder] = []
    @Published private(set) var notes: [NoteDocument] = []
    @Published private(set) var deletedFolders: [NoteFolder] = []
    @Published private(set) var deletedNotes: [NoteDocument] = []
    @Published private(set) var selectedID: UUID?
    @Published var folderID: UUID?
    @Published var search = ""
    @Published var sortOrder = 0
    @Published var searchWholeLibrary = true
    @Published private(set) var virtualScope = 0
    @Published var lastImportIssues: [NotebookImportIssue] = []
    @Published var title = ""
    @Published private(set) var saveStatus = "所有笔记仅保存在这台 Mac"
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var transitioning = false
    @Published private(set) var recoveryDrafts: [NotebookDraftEnvelope] = []
    @Published var openedAsset: NoteAsset?
    @Published private(set) var selectedAssets: [NoteAsset] = []
    let editor = NoteEditorController()
    private var store: JournalStore?
    private var worker: NotebookDatabaseWorker?
    private var draftStore: NotebookDraftStore?
    private var current: NoteDocument?
    private var gate: NotebookEditGate?
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private var editorVisible = false
    private var listPreviews: [UUID: String] = [:]
    var selected: NoteDocument? { current }
    func preview(for id: UUID) -> String { listPreviews[id] ?? "" }
    var visibleNotes: [NoteDocument] {
        var included = Set<UUID>()
        if let folderID {
            included.insert(folderID)
            for _ in 0..<NotebookValidation.maximumFolderDepth { for folder in folders where folder.parentID.map(included.contains) == true { included.insert(folder.id) } }
        }
        return notes.filter { note in
            let scopeMatches = virtualScope == 1 ? note.folderID == nil : (virtualScope == 2 ? note.updatedAt >= Date().addingTimeInterval(-7 * 86400) : (folderID == nil || note.folderID.map(included.contains) == true))
            return ((!search.isEmpty && searchWholeLibrary) || scopeMatches) && (search.isEmpty || note.title.localizedCaseInsensitiveContains(search) || note.markdown.localizedCaseInsensitiveContains(search))
        }
            .sorted { sortOrder == 1 ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : (sortOrder == 2 ? $0.createdAt > $1.createdAt : $0.updatedAt > $1.updatedAt) }
    }
    func configure(store: JournalStore, directory: URL) throws {
        self.store = store; worker = NotebookDatabaseWorker(url: directory.appendingPathComponent("journal.sqlite")); draftStore = NotebookDraftStore(directory: directory.appendingPathComponent("NotebookDrafts"))
        editor.onChange = { [weak self] in self?.receive($0) }
        editor.onError = { [weak self] in self?.error = $0 }
        editor.onSaveRequested = { [weak self] in self?.perform { try await self?.flush() } }
        editor.openNote = { [weak self] id in
            guard let self else { return }
            guard self.notes.contains(where: { $0.id == id }) else { self.error = "目标笔记尚未导入或已移入回收站。"; return }
            self.select(id)
        }
        editor.assetProvider = { [weak self] owner, id in
            guard let asset = try? self?.database().noteAsset(id: id), asset.ownerNoteID == owner else { return nil }
            return asset
        }
        editor.importImage = { [weak self] owner, data, name, mime in
            guard let self else { throw JournalError.invalid("笔记编辑器已关闭") }
            guard self.notes.contains(where: { $0.id == owner }), data.count <= NotebookValidation.maximumAssetBytes,
                  let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
                  image.size.width * image.size.height <= 40_000_000 else { throw JournalError.invalid("图片无法读取或尺寸过大。") }
            let asset = NoteAsset(ownerNoteID: owner, fileName: name, mimeType: mime, kind: .image, data: data)
            try self.database().saveNoteAsset(asset); if self.selectedID == owner { self.selectedAssets.append(asset) }; return asset
        }
        editor.openAsset = { [weak self] owner, id in
            guard let self, let asset = try? self.database().noteAsset(id: id), asset.ownerNoteID == owner else { return }
            self.openedAsset = asset
        }
        try reload()
        try recoverDrafts()
    }
    private func database() throws -> JournalStore {
        guard let store else { throw JournalError.invalid("笔记存储尚未就绪，请重启应用。") }; return store
    }
    func reload() throws {
        let allFolders = try database().noteFolders(includeDeleted: true), allNotes = try database().notes(includeDeleted: true)
        folders = allFolders.filter { $0.deletedAt == nil }; deletedFolders = allFolders.filter { $0.deletedAt != nil }
        notes = allNotes.filter { $0.deletedAt == nil }; deletedNotes = allNotes.filter { $0.deletedAt != nil }
        listPreviews = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, NotebookListPreview.text($0.markdown)) })
        if let folderID, !folders.contains(where: { $0.id == folderID }) { self.folderID = nil }
    }
    func enter() {
        editorVisible = true
        if let current {
            editor.load(noteID: current.id, markdown: current.markdown, revision: current.revision)
            if gate?.sessionID != editor.sessionID { gate = NotebookEditGate(noteID: current.id, sessionID: editor.sessionID) }
        }
    }
    func leave() async throws { try await flush(); editorVisible = false }
    func select(_ id: UUID?) { perform { try await self.flush(); self.load(id) } }
    func selectFolder(_ id: UUID?) {
        perform {
            try await self.flush(); self.folderID = id; self.virtualScope = 0
            if let current = self.current, id != nil && current.folderID != id { self.load(nil) }
        }
    }
    var scopeTitle: String {
        if !search.isEmpty && searchWholeLibrary { return "全库搜索" }
        return virtualScope == 1 ? "未分类" : (virtualScope == 2 ? "最近 7 天编辑" : path(of: folderID))
    }
    func selectVirtual(_ scope: Int) {
        perform { try await self.flush(); self.folderID = nil; self.virtualScope = scope; self.load(nil) }
    }
    private func load(_ id: UUID?) {
        saveTask?.cancel(); current = notes.first { $0.id == id }; selectedID = current?.id; title = current?.title ?? ""; dirty = false
        selectedAssets = current.flatMap { try? database().noteAssets(noteID: $0.id) } ?? []
        guard let current else { gate = nil; saveStatus = "选择一篇笔记开始阅读或编辑"; return }
        editor.load(noteID: current.id, markdown: current.markdown, revision: current.revision, force: true)
        gate = NotebookEditGate(noteID: current.id, sessionID: editor.sessionID)
        saveStatus = "已保存到本机"
    }
    func changeTitle(_ value: String) {
        guard current != nil else { return }; title = value; current?.title = value; changed()
    }
    private func receive(_ update: NoteEditorUpdate) {
        guard update.noteID == current?.id, update.sessionID == editor.sessionID else { return }
        if gate?.sessionID != update.sessionID { gate = NotebookEditGate(noteID: update.noteID, sessionID: update.sessionID) }
        guard gate?.accept(noteID: update.noteID, sessionID: update.sessionID, sequence: update.sequence) == true else { return }
        guard update.markdown != current?.markdown else { return }
        current?.markdown = update.markdown; changed()
    }
    private func changed() {
        dirty = true; saveStatus = "正在保存…"
        do { try journal() } catch { self.error = "草稿暂存失败，请保留窗口并复制内容：" + error.localizedDescription; saveStatus = "保存失败"; return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)); try self?.saveCurrent() }
            catch is CancellationError {} catch { self?.saveStatus = "保存失败 · 草稿已保留"; self?.error = error.localizedDescription }
        }
    }
    private func journal() throws {
        guard let current, let gate else { return }
        try draftStore?.save(NotebookDraftEnvelope(noteID: current.id, sessionID: editor.sessionID, baseRevision: current.revision, sequence: gate.lastSequence, title: title, markdown: current.markdown))
    }
    private func saveCurrent() throws {
        guard dirty, var value = current else { return }
        value.title = title.isEmpty ? "未命名笔记" : title; value.updatedAt = Date()
        let saved = try database().saveNote(value, expectedRevision: value.revision)
        current = saved; title = saved.title; dirty = false
        try draftStore?.remove(noteID: saved.id)
        try reload(); saveStatus = "已保存到本机 · " + saved.updatedAt.formatted(date: .omitted, time: .shortened)
    }
    func flush() async throws {
        saveTask?.cancel()
        if editorVisible, current != nil {
            let update = try await editor.flush(); receive(update)
        }
        saveTask?.cancel(); try saveCurrent()
    }
    func createNote() {
        perform {
            try await self.flush()
            let note = try self.database().saveNote(NoteDocument(folderID: self.folderID))
            try self.reload(); self.load(note.id)
        }
    }
    func createFolder(name: String, parent: UUID?) {
        perform { try await self.flush(); let folder = NoteFolder(parentID: parent, name: name); try self.database().saveNoteFolder(folder); try self.reload(); self.folderID = folder.id; self.virtualScope = 0; self.load(nil) }
    }
    func renameFolder(_ folder: NoteFolder, name: String) {
        perform { var value = folder; value.name = name; value.updatedAt = Date(); try self.database().saveNoteFolder(value); try self.reload() }
    }
    func moveFolder(_ folder: NoteFolder, to parent: UUID?) {
        perform { try await self.flush(); var value = folder; value.parentID = parent; value.updatedAt = Date(); try self.database().saveNoteFolder(value); try self.reload() }
    }
    func moveNote(_ note: NoteDocument, to folder: UUID?) {
        perform {
            try await self.flush(); guard var value = self.notes.first(where: { $0.id == note.id }) else { return }
            value.folderID = folder; value.updatedAt = Date(); let saved = try self.database().saveNote(value, expectedRevision: value.revision)
            try self.reload(); if self.selectedID == saved.id { self.current = saved }
        }
    }
    func deleteNote(_ id: UUID) {
        perform { try await self.flush(); try self.database().deleteNote(id: id); try self.reload(); if self.selectedID == id { self.load(nil) } }
    }
    func deleteFolder(_ id: UUID) {
        perform { try await self.flush(); try self.database().deleteNoteFolder(id: id); try self.reload(); if let selected = self.selectedID, !self.notes.contains(where: { $0.id == selected }) { self.load(nil) } }
    }
    func restoreNote(_ id: UUID) { perform { try self.database().restoreNote(id: id); try self.reload() } }
    func restoreFolder(_ id: UUID) { perform { try self.database().restoreNoteFolder(id: id); try self.reload() } }
    func destroyNote(_ id: UUID) { perform { try self.database().permanentlyDeleteNote(id: id); try self.draftStore?.remove(noteID: id); try self.reload() } }
    func destroyFolder(_ id: UUID) { perform { try self.database().permanentlyDeleteNoteFolder(id: id); try self.reload() } }
    func path(of id: UUID?) -> String {
        guard let id, let folder = folders.first(where: { $0.id == id }) else { return "笔记本" }
        if folder.parentID == nil { return folder.name }; return path(of: folder.parentID) + " / " + folder.name
    }
    func assetsForSelection() -> [NoteAsset] { guard let selectedID else { return [] }; return (try? database().noteAssets(noteID: selectedID)) ?? [] }
    func importPlan(_ plan: NotebookImportPlan, target: UUID? = nil) async throws -> NotebookImportResult {
        try await flush(); try Task.checkCancellation(); var snapshot = plan.snapshot
        if let target {
            guard folders.contains(where: { $0.id == target }) else { throw JournalError.invalid("导入目标目录已变化，请重新选择。") }
            for index in snapshot.notes.indices where snapshot.notes[index].folderID == nil { snapshot.notes[index].folderID = target }
            for index in snapshot.folders.indices where snapshot.folders[index].parentID == nil { snapshot.folders[index].parentID = target }
            var ancestor: UUID? = target
            while let id = ancestor, let folder = folders.first(where: { $0.id == id }) { snapshot.folders.append(folder); ancestor = folder.parentID }
        }
        guard let worker else { throw JournalError.invalid("笔记存储尚未就绪。") }
        let result = try await worker.importNotebook(snapshot); try reload(); return result
    }
    func handleDrop(_ text: String, destination: UUID?) -> Bool {
        if text.hasPrefix("workjournal-note:"), let id = UUID(uuidString: String(text.dropFirst(17))), let note = notes.first(where: { $0.id == id }) { moveNote(note, to: destination); return true }
        if text.hasPrefix("workjournal-folder:"), let id = UUID(uuidString: String(text.dropFirst(19))), let folder = folders.first(where: { $0.id == id }) { moveFolder(folder, to: destination); return true }
        return false
    }
    func exportSnapshot(scope: Int) async throws -> NotebookSnapshot {
        try await flush(); try Task.checkCancellation()
        guard let worker else { throw JournalError.invalid("笔记存储尚未就绪。") }
        var includedFolders = Set<UUID>()
        let selected: [NoteDocument]
        if scope == 2 { selected = notes.filter { $0.id == selectedID } }
        else if scope == 1, let folderID {
            includedFolders.insert(folderID)
            for _ in 0..<NotebookValidation.maximumFolderDepth { for folder in folders where folder.parentID.map(includedFolders.contains) == true { includedFolders.insert(folder.id) } }
            selected = notes.filter { $0.folderID.map(includedFolders.contains) == true }
        } else { selected = notes; includedFolders = Set(folders.map(\.id)) }
        includedFolders.formUnion(selected.compactMap(\.folderID))
        for _ in 0..<NotebookValidation.maximumFolderDepth { for folder in folders where includedFolders.contains(folder.id) { if let parent = folder.parentID { includedFolders.insert(parent) } } }
        return try await worker.snapshot(noteIDs: Set(selected.map(\.id)), folderIDs: includedFolders)
    }
    private func recoverDrafts() throws {
        guard let draftStore else { return }
        recoveryDrafts = try draftStore.conflicts()
        for id in try draftStore.noteIDs() {
            do {
                guard let draft = try draftStore.load(noteID: id) else { continue }
                guard var note = notes.first(where: { $0.id == id }) else { try draftStore.archiveConflict(draft); recoveryDrafts.append(draft); continue }
                switch draft.recovery(against: note) {
                case .alreadySaved: try draftStore.remove(noteID: id)
                case .restore:
                    note.title = draft.title; note.markdown = draft.markdown; note.updatedAt = Date()
                    _ = try database().saveNote(note, expectedRevision: draft.baseRevision); try draftStore.remove(noteID: id)
                    notice = "已恢复上次尚未保存的笔记草稿"
                case .conflict: try draftStore.archiveConflict(draft); recoveryDrafts.append(draft)
                }
            } catch { self.error = "有一份草稿未能自动恢复，原文件已保留：" + error.localizedDescription }
        }
        try reload()
    }
    func recoverAsCopy(_ draft: NotebookDraftEnvelope) {
        perform {
            try await self.flush()
            var note = NoteDocument(title: String((draft.title + "（恢复副本）").prefix(500)), markdown: draft.markdown)
            let assets = try self.database().noteAssets(noteID: draft.noteID).map { old -> NoteAsset in
                let asset = NoteAsset(ownerNoteID: note.id, fileName: old.fileName, mimeType: old.mimeType, kind: old.kind, data: old.data)
                note.markdown = note.markdown.replacingOccurrences(of: old.reference, with: asset.reference)
                return asset
            }
            _ = try self.database().importNotebook(NotebookSnapshot(notes: [note], assets: assets))
            try self.draftStore?.removeConflict(draft); self.recoveryDrafts.removeAll { $0.sessionID == draft.sessionID }
            try self.reload(); self.load(note.id)
        }
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !transitioning else { return }; transitioning = true
        Task { defer { transitioning = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
