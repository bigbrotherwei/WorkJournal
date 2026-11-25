import SwiftUI
import JournalCore

struct BackupSettingsSummaryView: View {
    @ObservedObject var coordinator: AutomaticBackupCoordinator
    @ViewState private var showing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(coordinator.settings.enabled ? "每日有变化时自动保存，保留最近 \(coordinator.settings.retentionCount) 份。" : "自动备份已关闭，可随时手动备份。")
            if let date = coordinator.state.lastSuccess { Text("上次成功：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            if let error = coordinator.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("管理自动备份") { showing = true }; if coordinator.busy { ProgressView().controlSize(.small); Text("处理中…").font(.caption).foregroundStyle(.secondary) } }
        }.sheet(isPresented: $showing) { BackupSettingsView(coordinator: coordinator) }
    }
}
