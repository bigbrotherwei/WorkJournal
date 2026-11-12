import SwiftUI
import JournalCore

struct NotebookTrashView: View {
    @ObservedObject var model: NotebookModel
    @ViewState private var destroyingNote: NoteDocument?
    @ViewState private var destroyingFolder: NoteFolder?
    var body: some View {
        Group {
            if model.deletedNotes.isEmpty && model.deletedFolders.isEmpty {
                ContentUnavailableView("没有已删除的笔记", systemImage: "trash", description: Text("移入回收站的笔记、目录与附件会保留在这里。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.deletedFolders.sorted { $0.name < $1.name }) { folder in
                            HStack {
                                JournalSymbol(name: "folder", tone: .violet)
                                VStack(alignment: .leading, spacing: 4) { Text(folder.name).font(.headline); Text("恢复目录时，一并恢复本次删除的子目录和笔记。").font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Button("恢复") { model.restoreFolder(folder.id) }; Button("永久删除", role: .destructive) { destroyingFolder = folder }
                            }.journalCard(padding: 14)
                        }
                        ForEach(model.deletedNotes.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }) { note in
                            HStack {
                                JournalSymbol(name: "doc.text", tone: .neutral)
                                VStack(alignment: .leading, spacing: 4) { Text(note.title).font(.headline); if let date = note.deletedAt { Text("删除于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
                                Spacer(); Button("恢复") { model.restoreNote(note.id) }; Button("永久删除", role: .destructive) { destroyingNote = note }
                            }.journalCard(padding: 14)
                        }
                    }
                }
            }
        }
        .alert("永久删除笔记？", isPresented: Binding(get: { destroyingNote != nil }, set: { if !$0 { destroyingNote = nil } })) {
            Button("取消", role: .cancel) { destroyingNote = nil }
            Button("永久删除", role: .destructive) { if let note = destroyingNote { model.destroyNote(note.id) }; destroyingNote = nil }
        } message: { Text("正文、图片和附件将被删除，无法撤销。已有导出备份不受影响。") }
        .alert("永久删除目录及其内容？", isPresented: Binding(get: { destroyingFolder != nil }, set: { if !$0 { destroyingFolder = nil } })) {
            Button("取消", role: .cancel) { destroyingFolder = nil }
            Button("永久删除", role: .destructive) { if let folder = destroyingFolder { model.destroyFolder(folder.id) }; destroyingFolder = nil }
        } message: { Text("此目录、子目录以及其中的笔记和附件将被永久删除，无法撤销。") }
        .alert("笔记操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
