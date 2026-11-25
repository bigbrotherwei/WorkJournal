import SwiftUI
import AppKit
import JournalCore

struct BackupSettingsView: View {
    @ObservedObject var coordinator: AutomaticBackupCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("自动备份", systemImage: "externaldrive.badge.timemachine").font(.title2.bold())
                Spacer()
                if coordinator.busy { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("应用运行期间每天检查资料变化，有变化时保存本地备份。包含记录、日报、周报、笔记、资源、笔记历史、应用设置与自定义模板。未保存的草稿不在备份中。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Toggle("启用每日自动备份", isOn: Binding(get: { coordinator.settings.enabled }, set: { coordinator.update(enabled: $0) }))
                HStack {
                    Text("保留份数")
                    Stepper(value: Binding(get: { coordinator.settings.retentionCount }, set: { coordinator.update(retentionCount: $0) }), in: 1...365) { Text("\(coordinator.settings.retentionCount) 份").monospacedDigit() }
                    Spacer()
                    Button("立即备份") { coordinator.backupNow() }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("备份目录").font(.caption).foregroundStyle(.secondary)
                        Text(coordinator.settings.directory.path).font(.callout).textSelection(.enabled).lineLimit(2)
                    }
                    Spacer()
                    Button("选择目录…") { coordinator.chooseDirectory() }
                    Button("打开目录") { NSWorkspace.shared.open(coordinator.settings.directory) }
                }
                Text("仅在新备份写入并校验成功后，清理本资料库生成的过期自动备份；其他文件保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }.journalCard(padding: 16).disabled(coordinator.busy || !coordinator.ready)
            VStack(alignment: .leading, spacing: 6) {
                if let date = coordinator.state.lastSuccess { Text("上次成功：\(date.formatted(date: .abbreviated, time: .standard))").font(.callout) }
                Text(coordinator.state.lastResult ?? "尚未生成自动备份").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let error = coordinator.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            }
            HStack { Text("可恢复备份").font(.headline); Spacer(); Button("刷新") { coordinator.refresh() }.disabled(coordinator.busy) }
            if coordinator.files.isEmpty {
                ContentUnavailableView("暂无自动备份", systemImage: "externaldrive", description: Text("可以点击“立即备份”保存当前资料。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(coordinator.files) { file in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(file.createdAt.formatted(date: .abbreviated, time: .standard)).font(.headline)
                                    Text("\(file.preview.entries) 条记录 · \(file.preview.notes) 篇笔记 · \(file.preview.versions) 个历史版本 · \(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("预览与恢复") { coordinator.preview(file) }.disabled(coordinator.busy)
                            }.journalCard(padding: 12)
                        }
                    }
                }
            }
        }.padding(24).frame(width: 750, height: 650)
            .background(JournalTheme.canvas).buttonStyle(JournalSecondaryButtonStyle()).tint(JournalTheme.accent)
            .onAppear { coordinator.refresh() }
            .sheet(item: $coordinator.previewFile) { file in
                VStack(alignment: .leading, spacing: 18) {
                    Label("恢复预览", systemImage: "arrow.counterclockwise").font(.title2.bold())
                    Text(file.url.lastPathComponent).font(.caption).textSelection(.enabled)
                    Text("记录 \(file.preview.entries) 条\n日报 \(file.preview.reports) 个版本\n周报/范围总结 \(file.preview.summaries) 个版本\n笔记 \(file.preview.notes) 篇，目录 \(file.preview.folders) 个\n资源 \(file.preview.assets) 个，笔记历史 \(file.preview.versions) 个\n自定义模板 \(file.preview.customTemplates) 个\n应用设置：\(file.preview.hasPreferences ? "已包含，可在下一步选择恢复" : "旧版备份未包含，保留本机设置")")
                        .lineSpacing(7)
                    Text("合并时保留本机同 ID 内容和模板，只补回缺失资料。下一步可选择是否恢复应用设置，默认保留当前设置与备份目录。恢复前会先备份本机资料。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("取消") { coordinator.previewFile = nil }; Button("继续合并恢复") { coordinator.restorePreviewedBackup() } }
                }.padding(24).frame(width: 460).background(JournalTheme.canvas)
                    .buttonStyle(JournalSecondaryButtonStyle()).tint(JournalTheme.accent)
            }
    }
}
