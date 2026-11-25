import SwiftUI
import JournalCore

struct NotebookHistoryView: View {
    let note: NoteDocument
    let load: () throws -> [NoteVersion]
    let checkpoint: () throws -> Void
    let restore: (UUID, Int) throws -> NoteDocument
    let onRestored: (NoteDocument) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var versions: [NoteVersion] = []
    @ViewState private var selection: UUID?
    @ViewState private var failure: String?
    @ViewState private var confirmingRestore = false
    private var selected: NoteVersion? { versions.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("笔记历史", systemImage: "clock.arrow.circlepath").font(.title2.bold())
                Spacer()
                Button("保存当前快照") { perform { try checkpoint(); try reload() } }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("连续编辑每 5 分钟保留一个检查点，并保留首次编辑前内容。最多保留 100 个版本、约 32 MiB；恢复前会保存当前内容。")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                List(versions, selection: $selection) { version in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(version.savedAt.formatted(date: .abbreviated, time: .standard)).font(.callout)
                        Text(reason(version.reason)).font(.caption).foregroundStyle(.secondary)
                        Text(version.title.isEmpty ? "未命名笔记" : version.title).font(.caption).lineLimit(1)
                    }.padding(.vertical, 4).tag(version.id)
                }.frame(minWidth: 185, idealWidth: 210, maxWidth: 260)
                if let selected {
                    HStack(alignment: .top, spacing: 12) {
                        comparison(title: "历史版本", documentTitle: selected.title, markdown: selected.markdown)
                        comparison(title: "当前版本", documentTitle: note.title, markdown: note.markdown)
                    }.padding(.leading, 10)
                } else {
                    ContentUnavailableView("暂无历史版本", systemImage: "clock", description: Text("修改标题或正文后，会自动保留编辑前内容；也可手动保存快照。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack {
                Text("\(versions.count) 个历史版本 · 对照显示原始 Markdown，资源引用保留。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复所选版本") { confirmingRestore = true }.disabled(selected == nil)
            }
        }.padding(24).frame(minWidth: 880, idealWidth: 1000, minHeight: 580)
            .background(JournalTheme.canvas).buttonStyle(JournalSecondaryButtonStyle()).tint(JournalTheme.accent)
            .onAppear { perform { try reload() } }
            .alert("恢复此历史版本？", isPresented: $confirmingRestore) {
                Button("取消", role: .cancel) {}
                Button("保存当前内容并恢复") {
                    guard let selected else { return }
                    perform { let restored = try restore(selected.id, note.revision); onRestored(restored); dismiss() }
                }
            } message: { Text("当前标题和正文会先保存到历史中。笔记所在目录保持不变。") }
    }
    private func comparison(title: String, documentTitle: String, markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(documentTitle.isEmpty ? "未命名笔记" : documentTitle).font(.title3).textSelection(.enabled)
            ScrollView { Text(markdown.isEmpty ? "（正文为空）" : markdown).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }
                .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func reason(_ reason: NoteVersionReason) -> String {
        switch reason { case .automatic: "编辑前自动保存"; case .manual: "手动快照"; case .beforeRestore: "恢复前保存" }
    }
    private func reload() throws {
        versions = try load()
        if !versions.contains(where: { $0.id == selection }) { selection = versions.first?.id }
    }
    private func perform(_ work: () throws -> Void) { do { try work(); failure = nil } catch { failure = error.localizedDescription } }
}
