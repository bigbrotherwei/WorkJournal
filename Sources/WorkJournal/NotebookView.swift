import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import JournalCore

struct NotebookView: View {
    @ObservedObject var model: NotebookModel
    var backup: () -> Void
    var restoreBackup: () -> Void
    @AppStorage("notebook.foldersHidden") private var foldersHidden = false
    @AppStorage("notebook.listHidden") private var listHidden = false
    @ViewState private var action: NotebookAction?
    @ViewState private var showingTransfer = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { foldersHidden.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(foldersHidden ? "展开目录" : "收起目录").accessibilityLabel(foldersHidden ? "展开目录" : "收起目录")
                Button { listHidden.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                    .help(listHidden ? "展开笔记列表" : "收起笔记列表").accessibilityLabel(listHidden ? "展开笔记列表" : "收起笔记列表")
                Text("笔记本").font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                Button { showingTransfer = true } label: { Label("导入 / 导出", systemImage: "arrow.up.arrow.down") }
                Button(action: model.createNote) { Label("新建笔记", systemImage: "square.and.pencil") }.buttonStyle(JournalPrimaryButtonStyle())
            }.padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(JournalTheme.border)
            HSplitView {
                if !foldersHidden {
                    directoryPane.frame(minWidth: 160, idealWidth: 176, maxWidth: 380, maxHeight: .infinity)
                }
                if !listHidden {
                    listPane.frame(minWidth: 178, idealWidth: 216, maxWidth: 480, maxHeight: .infinity)
                }
                documentPane.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(JournalTheme.paper)
            .onAppear { model.enter() }
            .sheet(item: $action) { NotebookActionSheet(model: model, action: $0) }
            .sheet(isPresented: $showingTransfer) { NotebookTransferView(model: model, backup: backup, restoreBackup: restoreBackup) }
            .sheet(item: $model.openedAsset) { NotebookAssetView(asset: $0) }
            .alert("笔记操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    HStack { Text(notice); Button("知道了") { model.notice = nil } }.font(.caption).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
            }
    }
    private var directoryPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("目录").font(.caption).foregroundStyle(.secondary); Spacer(); Button { action = .createFolder(parent: model.folderID) } label: { Image(systemName: "folder.badge.plus") }.help("新建目录") }.padding(.horizontal, 12).padding(.top, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Button { selectFolder(nil) } label: {
                        HStack { Image(systemName: "books.vertical"); Text("全部笔记"); Spacer(); Text(model.notes.count.formatted()).foregroundStyle(.secondary) }.padding(9).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(model.folderID == nil && model.virtualScope == 0 ? JournalTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .onDrop(of: [UTType.text], delegate: NotebookMoveDrop(model: model, destination: nil))
                    Button { selectVirtual(1) } label: { Label("未分类", systemImage: "tray").frame(maxWidth: .infinity, alignment: .leading).padding(9).contentShape(Rectangle()) }.buttonStyle(.plain).background(model.virtualScope == 1 ? JournalTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
                    Button { selectVirtual(2) } label: { Label("最近编辑", systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading).padding(9).contentShape(Rectangle()) }.buttonStyle(.plain).background(model.virtualScope == 2 ? JournalTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
                    Divider().padding(.vertical, 5)
                    ForEach(model.folders.filter { $0.parentID == nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                        NotebookFolderRow(model: model, folder: folder, depth: 0, selectFolder: { selectFolder($0) }, action: { action = $0 })
                    }
                }.padding(.horizontal, 8)
            }
            if model.folders.isEmpty { Text("建立目录，把相关笔记放在一起。") .font(.caption).foregroundStyle(.secondary).padding(12) }
        }.background(JournalTheme.sidebar)
    }
    private func selectFolder(_ id: UUID?) {
        listHidden = false
        model.selectFolder(id)
    }
    private func selectVirtual(_ scope: Int) {
        listHidden = false
        model.selectVirtual(scope)
    }
    private var listPane: some View {
        let visibleNotes = model.visibleNotes
        return VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索标题和正文", text: $model.search).textFieldStyle(.plain) }.padding(10).background(JournalTheme.canvas, in: RoundedRectangle(cornerRadius: 10)).padding(12)
            if !model.search.isEmpty { Toggle("全库搜索", isOn: $model.searchWholeLibrary).toggleStyle(.checkbox).font(.caption).padding(.horizontal, 14).padding(.bottom, 8) }
            HStack(spacing: 8) {
                Text(model.scopeTitle).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(visibleNotes.count) 篇").monospacedDigit().fixedSize()
                sortMenu
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(visibleNotes) { note in
                        Button { model.select(note.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(note.title.isEmpty ? "未命名笔记" : note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(JournalTheme.ink).lineLimit(2)
                                Text(model.preview(for: note.id)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if !model.search.isEmpty { Text(model.path(of: note.folderID)).font(.system(size: 10)).foregroundStyle(JournalTheme.accent).lineLimit(1) }
                                Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).padding(12).background(model.selectedID == note.id ? JournalTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                        }.buttonStyle(.plain).onDrag { NSItemProvider(object: ("workjournal-note:" + note.id.uuidString) as NSString) }.contextMenu {
                            Button("移动到…") { action = .moveNote(note) }
                            Button("移到回收站", role: .destructive) { model.deleteNote(note.id) }
                        }
                    }
                }.padding(.horizontal, 8)
                if visibleNotes.isEmpty { Text(model.search.isEmpty ? "这里还没有笔记" : "没有找到匹配的笔记").font(.caption).foregroundStyle(.secondary).padding(20) }
            }
        }.background(JournalTheme.paper)
    }
    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $model.sortOrder) {
                Text("最近更新").tag(0)
                Text("标题").tag(1)
                Text("创建时间").tag(2)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(JournalTheme.accent)
                .frame(width: 30, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
        .frame(width: 32, height: 28).fixedSize().layoutPriority(1)
        .background(JournalTheme.soft, in: RoundedRectangle(cornerRadius: 8))
        .help("排序").accessibilityLabel("笔记排序")
    }
    private var documentPane: some View {
        VStack(spacing: 0) {
            if !model.recoveryDrafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("发现未保存草稿，已保留原稿供你恢复", systemImage: "arrow.counterclockwise.circle").font(.caption)
                    ForEach(model.recoveryDrafts) { draft in
                        HStack { Text(draft.title).lineLimit(1); Spacer(); Button("恢复为副本") { model.recoverAsCopy(draft) } }.font(.caption)
                    }
                }.padding(12).background(JournalTheme.soft)
            }
            if let note = model.selected {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.path(of: note.folderID)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Menu {
                            Button("移动到…") { action = .moveNote(note) }
                            Button("移到回收站", role: .destructive) { model.deleteNote(note.id) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                    }
                    TextField("未命名笔记", text: Binding(get: { model.title }, set: model.changeTitle)).textFieldStyle(.plain).font(.system(size: 25, weight: .semibold, design: .rounded))
                    HStack(spacing: 6) { Circle().fill(JournalTheme.accent).frame(width: 5, height: 5); Text(model.saveStatus).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if !note.tags.isEmpty { Text(note.tags.map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(JournalTheme.accent).lineLimit(2) }
                    if !model.selectedAssets.filter({ $0.kind != .image }).isEmpty {
                        ScrollView(.horizontal) {
                            HStack { ForEach(model.selectedAssets.filter { $0.kind != .image }) { asset in
                                Button { model.openedAsset = asset } label: { Label(asset.fileName, systemImage: asset.kind == .pdf ? "doc.richtext" : "paperclip").lineLimit(1) }.help("打开原始附件")
                            } }
                        }
                    }
                }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
                NoteEditorView(controller: model.editor)
            } else {
                Spacer()
                JournalSymbol(name: "book.closed", tone: .violet, size: 60)
                Text("留一点空间，给你的想法").font(.system(size: 19, weight: .medium, design: .rounded)).padding(.top, 12)
                Text("选择一篇笔记，或开始新的记录。\n文字、图片和附件都保存在本机。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
                Button("新建笔记", action: model.createNote).buttonStyle(JournalPrimaryButtonStyle()).padding(.top, 16)
                Spacer()
            }
        }
    }
}

private struct NotebookFolderRow: View {
    @ObservedObject var model: NotebookModel
    let folder: NoteFolder
    let depth: Int
    let selectFolder: (UUID) -> Void
    let action: (NotebookAction) -> Void
    @ViewState private var expanded = true
    private var children: [NoteFolder] { model.folders.filter { $0.parentID == folder.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12) }.buttonStyle(.plain).opacity(children.isEmpty ? 0 : 1).disabled(children.isEmpty)
                Button { selectFolder(folder.id) } label: {
                    HStack(spacing: 6) { Image(systemName: "folder").foregroundStyle(JournalTheme.accent); Text(folder.name).lineLimit(1); Spacer(minLength: 0) }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(.vertical, 8).padding(.horizontal, 6).padding(.leading, CGFloat(min(depth, 4)) * 10)
                .background(model.folderID == folder.id ? JournalTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
                .onDrag { NSItemProvider(object: ("workjournal-folder:" + folder.id.uuidString) as NSString) }
                .onDrop(of: [UTType.text], delegate: NotebookMoveDrop(model: model, destination: folder.id))
                .contextMenu {
                    Button("新建子目录") { action(.createFolder(parent: folder.id)) }
                    Button("重命名…") { action(.renameFolder(folder)) }
                    Button("移动到…") { action(.moveFolder(folder)) }
                    Button("移到回收站", role: .destructive) { action(.deleteFolder(folder)) }
                }
            if expanded { ForEach(children) { child in NotebookFolderRow(model: model, folder: child, depth: depth + 1, selectFolder: selectFolder, action: action) } }
        }
    }
}

private enum NotebookAction: Identifiable {
    case createFolder(parent: UUID?), renameFolder(NoteFolder), moveFolder(NoteFolder), moveNote(NoteDocument), deleteFolder(NoteFolder)
    var id: String { switch self { case .createFolder(let parent): return "create-\(parent?.uuidString ?? "root")"; case .renameFolder(let f): return "rename-\(f.id)"; case .moveFolder(let f): return "move-\(f.id)"; case .moveNote(let n): return "note-\(n.id)"; case .deleteFolder(let f): return "delete-\(f.id)" } }
}
private struct NotebookActionSheet: View {
    @ObservedObject var model: NotebookModel
    let action: NotebookAction
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var destination: UUID?
    private var heading: String { switch action { case .createFolder: return "新建目录"; case .renameFolder: return "重命名目录"; case .deleteFolder: return "将目录移到回收站？"; default: return "移动到目录" } }
    private var naming: Bool { switch action { case .createFolder, .renameFolder: return true; default: return false } }
    private var deleting: Bool { if case .deleteFolder = action { return true }; return false }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(heading).font(.title2.bold())
            if naming { TextField("目录名称", text: $name).textFieldStyle(.roundedBorder) }
            else if deleting { Text("目录中的笔记和子目录也会移入回收站，之后可以一同恢复。").foregroundStyle(.secondary) }
            else {
                Picker("目标目录", selection: $destination) {
                    Text("顶层").tag(nil as UUID?)
                    ForEach(model.folders.sorted { model.path(of: $0.id) < model.path(of: $1.id) }) { folder in Text(model.path(of: folder.id)).tag(Optional(folder.id)) }
                }
            }
            HStack { Button("取消", role: .cancel) { dismiss() }; Spacer(); Button(deleting ? "移到回收站" : "确定") { apply(); dismiss() }.buttonStyle(JournalPrimaryButtonStyle()).disabled(naming && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420).background(JournalTheme.canvas)
            .onAppear { switch action { case .renameFolder(let f): name = f.name; case .moveFolder(let f): destination = f.parentID; case .moveNote(let n): destination = n.folderID; default: break } }
    }
    private func apply() {
        switch action {
        case .createFolder(let parent): model.createFolder(name: name, parent: parent)
        case .renameFolder(let folder): model.renameFolder(folder, name: name)
        case .moveFolder(let folder): model.moveFolder(folder, to: destination)
        case .moveNote(let note): model.moveNote(note, to: destination)
        case .deleteFolder(let folder): model.deleteFolder(folder.id)
        }
    }
}

struct NotebookAssetView: View {
    let asset: NoteAsset
    @Environment(\.dismiss) private var dismiss
    @ViewState private var error: String?
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text(asset.fileName).font(.headline).lineLimit(1); Spacer(); Button("另存为…", action: save); Button("完成") { dismiss() } }
            if asset.kind == .pdf { NotebookPDFView(data: asset.data) }
            else if asset.kind == .image, let image = NSImage(data: asset.data) { ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 760, maxHeight: 600) } }
            else { ContentUnavailableView("原始附件已保留", systemImage: "doc", description: Text("可另存到本机后使用相应应用打开。")) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(20).frame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 660)
    }
    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: asset.fileName).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try asset.data.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
}
private struct NotebookPDFView: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view }
    func updateNSView(_ view: PDFView, context: Context) {}
}

private struct NotebookMoveDrop: DropDelegate {
    let model: NotebookModel
    let destination: UUID?
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String else { return }
            Task { @MainActor in _ = model.handleDrop(text, destination: destination) }
        }
        return true
    }
}
