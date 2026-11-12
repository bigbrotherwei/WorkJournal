import SwiftUI
import JournalCore

struct TrashView: View {
    @ObservedObject var app: AppModel
    @ViewState private var deleting: Entry?
    @ViewState private var kind = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: "回收站", subtitle: "删除的内容保留在这里，可恢复；不会自动清空。")
            Picker("内容类型", selection: $kind) { Text("记录").tag(0); Text("笔记与目录").tag(1) }.pickerStyle(.segmented)
            if kind == 1 { NotebookTrashView(model: app.notebook) } else {
            if app.trash.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash", description: Text("误删的记录和图片可以在这里找回。"))
            } else {
                ScrollView {
                LazyVStack(spacing: 14) {
                ForEach(app.trash) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            JournalSymbol(name: "archivebox", tone: .neutral)
                            Text(entry.day).font(.headline)
                            Text(entry.category).foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复") { app.restoreEntry(entry.id) }
                            Button("永久删除", role: .destructive) { deleting = entry }
                        }
                        if let deleted = entry.deletedAt { Text("删除于 " + deleted.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        RecordContentView(entry: entry)
                    }.journalCard(padding: 18)
                }
                }
                }
            }
            }
        }.padding(24)
        .alert("永久删除这条记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("永久删除", role: .destructive) { if let deleting { app.permanentlyDeleteEntry(deleting.id) }; deleting = nil }
        } message: { Text("文字和图片将从本机记录中移除，此操作无法撤销。已有导出备份不会被修改。") }
    }
}
