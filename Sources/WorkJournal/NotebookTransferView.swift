import SwiftUI
import AppKit
import JournalCore

@MainActor final class NotebookTransferModel: ObservableObject {
    @Published var source = NotebookImportSource.youdao
    @Published var format = NotebookExportFormat.markdown
    @Published var scope = 0
    @Published var target: UUID?
    @Published var mode = 0
    @Published var plan: NotebookImportPlan?
    @Published var path = ""
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    @Published var result: String?
    private var operation: Task<Void, Never>?
    private var preparation: Task<NotebookImportPlan, Error>?
    private var exporting: Task<URL, Error>?
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = source == .evernote ? "选择 ENEX 文件或包含导出文件的文件夹" : "选择笔记文件或导出的文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path; plan = nil; result = nil; error = nil; busy = true; progress = "正在读取文件…"
        let source = source
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try NotebookTransfer.prepareImport(at: url, source: source, cancelled: { Task<Never, Never>.isCancelled }) { [weak self] item in
                Task { @MainActor in self?.progress = "正在检查：" + item }
            }
        }
        preparation = worker
        operation = Task {
            defer { busy = false; preparation = nil }
            do { let value = try await worker.value; try Task.checkCancellation(); plan = value; progress = "检查完成，请确认导入" }
            catch is CancellationError { progress = "已取消，未导入任何笔记" }
            catch { if worker.isCancelled { progress = "已取消，未导入任何笔记" } else { self.error = error.localizedDescription } }
        }
    }
    func cancel() { preparation?.cancel(); exporting?.cancel(); operation?.cancel() }
    func commit(to model: NotebookModel) {
        guard let plan, !busy else { return }; busy = true; error = nil; progress = "正在保存到本机…"
        operation = Task {
            defer { busy = false }
            do {
                let imported = try await model.importPlan(plan, target: target)
                model.lastImportIssues = plan.issues
                result = "已导入 \(imported.notes) 篇笔记、\(imported.folders) 个目录、\(imported.assets) 个资源；跳过 \(imported.skipped) 个重复项。"
                if !imported.warnings.isEmpty { result! += "\n" + imported.warnings.joined(separator: "\n") }
                if !plan.issues.isEmpty { result! += "\n本批次有 \(plan.issues.count) 项格式或资源提示，请查看下方检查报告。" }
                self.plan = nil; progress = "导入完成"
            } catch is CancellationError { progress = "已取消，未导入任何笔记"; result = progress }
            catch { self.error = error.localizedDescription }
        }
    }
    func export(from model: NotebookModel) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "选择保存位置；将在其中创建新的导出目录，不覆盖已有文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil; result = nil; progress = "正在准备导出…"
        operation = Task {
            defer { busy = false; exporting = nil }
            do {
                let snapshot = try await model.exportSnapshot(scope: scope)
                guard !snapshot.notes.isEmpty || !snapshot.folders.isEmpty else { throw JournalError.invalid("当前范围没有可导出的笔记或目录。") }
                try Task.checkCancellation()
                let format = format
                let worker = Task.detached(priority: .userInitiated) { try NotebookTransfer.export(snapshot: snapshot, to: url, format: format, cancelled: { Task<Never, Never>.isCancelled }) }
                exporting = worker
                let target = try await worker.value; result = "已导出 \(snapshot.notes.count) 篇笔记到：\n" + target.path
                NSWorkspace.shared.activateFileViewerSelecting([target]); progress = "导出完成"
            } catch is CancellationError { progress = "已取消导出" }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct NotebookTransferView: View {
    @ObservedObject var model: NotebookModel
    let backup: () -> Void
    let restoreBackup: () -> Void
    @StateObject private var transfer = NotebookTransferModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                modeNavigation
            }.padding(24).padding(.bottom, -6)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if transfer.mode == 0 { importControls }
                    else if transfer.mode == 1 { exportControls }
                    else { backupControls }
                    if let error = transfer.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).journalCard(padding: 16)
                    }
                    if let result = transfer.result {
                        Label(result, systemImage: transfer.progress.hasPrefix("已取消") ? "minus.circle" : "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(transfer.progress.hasPrefix("已取消") ? JournalTheme.secondary : JournalTheme.accent)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).journalCard(padding: 16)
                    }
                    if transfer.mode == 0 && transfer.plan == nil && !model.lastImportIssues.isEmpty {
                        TransferIssueReport(title: "上次导入的检查报告", issues: model.lastImportIssues)
                    }
                }.padding(24).padding(.top, -6)
            }
            footer
        }
        .frame(width: 760, height: 620).background(JournalTheme.canvas)
        .foregroundStyle(JournalTheme.ink).tint(JournalTheme.accent)
        .interactiveDismissDisabled(transfer.busy)
        .onChange(of: transfer.source) { _, _ in transfer.plan = nil; transfer.path = ""; transfer.result = nil }
        .onDisappear { transfer.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            JournalSymbol(name: "arrow.up.arrow.down", size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("导入与导出").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("导入已有笔记，或将资料导出到本机。").font(.system(size: 12)).foregroundStyle(JournalTheme.secondary)
            }
            Spacer()
            Button("完成") { dismiss() }.buttonStyle(JournalSecondaryButtonStyle()).disabled(transfer.busy)
        }
    }

    private var modeNavigation: some View {
        HStack(spacing: 4) {
            modeButton("导入笔记", symbol: "square.and.arrow.down", value: 0)
            modeButton("导出笔记", symbol: "square.and.arrow.up", value: 1)
            modeButton("完整备份", symbol: "externaldrive", value: 2)
        }.padding(5)
            .background(JournalTheme.soft.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
            .disabled(transfer.busy).accessibilityElement(children: .contain).accessibilityLabel("操作模式")
    }

    private func modeButton(_ title: String, symbol: String, value: Int) -> some View {
        Button { transfer.mode = value } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: transfer.mode == value ? .semibold : .medium))
                .foregroundStyle(transfer.mode == value ? JournalTheme.accent : JournalTheme.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(transfer.mode == value ? JournalTheme.paper : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(transfer.mode == value ? .isSelected : [])
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("从哪里导入", detail: "选择原来的笔记格式")
            HStack(spacing: 10) {
                selectionCard("有道云笔记", detail: "目录 · Markdown · PDF", symbol: "doc.text", selected: transfer.source == .youdao) { transfer.source = .youdao }
                selectionCard("印象笔记", detail: "Evernote · ENEX · HTML", symbol: "book.closed", selected: transfer.source == .evernote) { transfer.source = .evernote }
                selectionCard("Markdown", detail: "正文与关联资源", symbol: "doc.plaintext", selected: transfer.source == .markdown) { transfer.source = .markdown }
            }.disabled(transfer.busy)
            Text(sourceHelp).font(.system(size: 12)).foregroundStyle(JournalTheme.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            fileEntry
            if let plan = transfer.plan {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("导入预览", detail: "检查完成，确认后保存到本机")
                    HStack(spacing: 10) {
                        count("篇笔记", plan.noteCount, symbol: "doc.text")
                        count("个目录", plan.folderCount, symbol: "folder")
                        count("个资源", plan.assetCount, symbol: "photo.on.rectangle")
                    }
                    Text("可编辑正文 \(plan.editableNoteCount) 篇 · 保留原文件 \(plan.preservedFileCount) 份 · " + ByteCountFormatter.string(fromByteCount: Int64(plan.totalBytes), countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(JournalTheme.secondary)
                    Picker("导入位置", selection: $transfer.target) {
                        Text("笔记本顶层").tag(nil as UUID?)
                        ForEach(model.folders) { folder in Text(model.path(of: folder.id)).tag(Optional(folder.id)) }
                    }.disabled(transfer.busy)
                    Text("保留可识别的目录；相同来源与内容会跳过重复项。")
                        .font(.system(size: 11)).foregroundStyle(JournalTheme.secondary)
                }.journalCard(padding: 18)
                if !plan.issues.isEmpty {
                    TransferIssueReport(title: "本次检查报告", issues: plan.issues).id(transfer.path)
                }
            }
        }
    }

    private var fileEntry: some View {
        HStack(spacing: 12) {
            JournalSymbol(name: transfer.path.isEmpty ? "folder.badge.plus" : "doc.badge.checkmark", size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.path.isEmpty ? "选择要导入的文件" : URL(fileURLWithPath: transfer.path).lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(transfer.path.isEmpty ? "支持单个文件，也可以选择整个导出文件夹。" : transfer.path)
                    .font(.system(size: 11)).foregroundStyle(JournalTheme.secondary).lineLimit(2)
                    .truncationMode(.middle).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .help(transfer.path.isEmpty ? "使用文件选择器选择文件或文件夹" : transfer.path)
            Button(transfer.path.isEmpty ? "选择文件…" : "重新选择…") { transfer.choose() }
                .buttonStyle(JournalSecondaryButtonStyle()).disabled(transfer.busy)
                .accessibilityLabel(transfer.path.isEmpty ? "选择文件或文件夹" : "重新选择文件或文件夹")
        }.padding(16).background(JournalTheme.soft.opacity(0.55), in: RoundedRectangle(cornerRadius: 17))
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("以哪种格式导出", detail: "两种格式都会保留目录和资源")
            HStack(spacing: 12) {
                selectionCard("Markdown", detail: "便于继续编辑与迁移", symbol: "doc.plaintext", selected: transfer.format == .markdown) { transfer.format = .markdown }
                selectionCard("HTML", detail: "可直接在浏览器阅读", symbol: "globe", selected: transfer.format == .html) { transfer.format = .html }
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("导出范围", systemImage: "square.stack.3d.up").font(.system(size: 13, weight: .semibold))
                Picker("包含的笔记", selection: $transfer.scope) {
                    Text("全部笔记").tag(0)
                    if model.folderID != nil { Text("当前目录及子目录").tag(1) }
                    if model.selectedID != nil { Text("当前笔记").tag(2) }
                }
                Text("图片与附件会放在资源文件夹中，通过相对路径关联。回收站内容仅包含在完整备份中。")
                    .font(.system(size: 12)).foregroundStyle(JournalTheme.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }.journalCard(padding: 18)
            Label("下一步选择保存位置，将创建新的导出目录。", systemImage: "folder.badge.plus")
                .font(.system(size: 12)).foregroundStyle(JournalTheme.secondary)
        }.disabled(transfer.busy)
    }

    private var backupControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("为整个工作空间留一份副本", detail: "笔记之外，日常记录与报告也一起保存")
            Text("包含记录、日报、周报、笔记目录、正文、图片、附件和回收站。")
                .font(.system(size: 12)).foregroundStyle(JournalTheme.secondary)
            backupCard("导出完整备份", detail: "保存一份本机数据副本，方便留存或迁移到另一台 Mac。", symbol: "externaldrive.badge.plus", tone: .violet, actionTitle: "导出备份…") { dismiss(); backup() }
            backupCard("从备份恢复", detail: "将备份合并到本机；同 ID 内容优先保留本机版本。", symbol: "arrow.counterclockwise", tone: .blue, actionTitle: "选择备份…") { dismiss(); restoreBackup() }
        }.disabled(transfer.busy)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if transfer.busy {
                ProgressView().controlSize(.small)
                Text(transfer.progress).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading).help(transfer.progress)
                Button("取消") { transfer.cancel() }.buttonStyle(JournalSecondaryButtonStyle())
            } else {
                Text(footerHint).font(.system(size: 11)).foregroundStyle(JournalTheme.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if transfer.mode == 0 {
                    if let plan = transfer.plan {
                        Button("确认导入 \(plan.noteCount) 篇笔记") { transfer.commit(to: model) }
                            .buttonStyle(JournalPrimaryButtonStyle()).disabled(plan.noteCount == 0)
                    } else {
                        Button("选择文件或文件夹…") { transfer.choose() }.buttonStyle(JournalPrimaryButtonStyle())
                    }
                } else if transfer.mode == 1 {
                    Button("选择保存位置并导出…") { transfer.export(from: model) }.buttonStyle(JournalPrimaryButtonStyle())
                }
            }
        }.padding(.horizontal, 24).frame(height: 72)
            .background(JournalTheme.paper)
            .overlay(alignment: .top) { Rectangle().fill(JournalTheme.border).frame(height: 1) }
    }

    private var footerHint: String {
        if transfer.progress.hasPrefix("已取消") { return transfer.progress }
        if transfer.mode == 0 { return transfer.plan == nil ? "先选择文件，检查后再确认导入。" : "检查结果已就绪，确认后开始导入。" }
        if transfer.mode == 1 { return "导出会新建目录，不覆盖已有文件。" }
        return "完整备份用于工作随记之间迁移与恢复。"
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 10)
            Text(detail).font(.system(size: 11)).foregroundStyle(JournalTheme.secondary)
        }
    }

    private func selectionCard(_ title: String, detail: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(JournalTheme.accent)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? JournalTheme.accent : JournalTheme.border)
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(JournalTheme.ink)
                    Text(detail).font(.system(size: 11)).foregroundStyle(JournalTheme.secondary).lineLimit(1)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? JournalTheme.soft : JournalTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? JournalTheme.accent.opacity(0.5) : JournalTheme.border))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityLabel(title + "，" + detail)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func backupCard(_ title: String, detail: String, symbol: String, tone: JournalTheme.Tone, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            JournalSymbol(name: symbol, tone: tone, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(JournalTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action).buttonStyle(JournalSecondaryButtonStyle())
        }.journalCard(padding: 20)
    }

    private func count(_ label: String, _ value: Int, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(JournalTheme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(value.formatted()).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 11)).foregroundStyle(JournalTheme.secondary)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity).background(JournalTheme.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityElement(children: .combine)
    }

    private var sourceHelp: String {
        switch transfer.source {
        case .youdao: return "支持导出的目录、Markdown、HTML 和 PDF。PDF 将保留原件供直接阅读，同时提取可识别的文字为可编辑内容；原排版以 PDF 为准。未知封装会保留并报告。"
        case .evernote: return "支持 ENEX / ENML / HTML，保留可识别的正文、图片、附件、标签和时间。ENEX 未包含的原笔记本层级无法还原；加密片段会保留提示。"
        case .markdown: return "导入 .md / .markdown 及关联图片和附件，保留源目录结构。不会自动下载远程资源。"
        }
    }
}

private struct TransferIssueReport: View {
    let title: String
    let issues: [NotebookImportIssue]
    @ViewState private var expanded = false
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.system(size: 13, weight: .semibold))
                            Text(summary).font(.system(size: 11)).foregroundStyle(JournalTheme.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title + "，" + summary)
                    .accessibilityValue(expanded ? "已展开" : "已折叠").accessibilityHint("显示或收起检查详情")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issues.map { $0.sourcePath + "：" + $0.message }.joined(separator: "\n"), forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制报告", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(JournalSecondaryButtonStyle()).accessibilityLabel("复制完整检查报告，共 \(issues.count) 项")
            }
            if expanded {
                Divider()
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(issues.prefix(100).enumerated()), id: \.offset) { _, issue in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: issue.severity == .error ? "exclamationmark.triangle" : "info.circle")
                                .foregroundStyle(issue.severity == .error ? .red : JournalTheme.accent)
                                .accessibilityLabel(issue.severity == .error ? "错误" : "提示")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.sourcePath).fontWeight(.medium)
                                Text(issue.message).foregroundStyle(JournalTheme.secondary)
                            }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if issues.count > 100 {
                        Text("显示前 100 项，还有 \(issues.count - 100) 项。复制完整报告可查看全部内容。")
                            .font(.system(size: 11)).foregroundStyle(JournalTheme.secondary)
                    }
                }
            }
        }.journalCard(padding: 16)
    }

    private var summary: String {
        let errors = issues.filter { $0.severity == .error }.count
        return "共 \(issues.count) 项 · \(errors) 项错误 · \(issues.count - errors) 项提示"
    }
}
