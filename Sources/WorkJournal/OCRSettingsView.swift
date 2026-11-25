import SwiftUI
import JournalCore

struct OCRSettingsView: View {
    @ObservedObject var coordinator: LocalOCRCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                JournalSymbol(name: "text.viewfinder", tone: .blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("图片文字搜索").font(.headline)
                    Text("手动识别记录和笔记中的图片，文字可在统一搜索中找到。").font(.caption).foregroundStyle(JournalTheme.secondary)
                }
                Spacer()
                if coordinator.isRunning {
                    Button(coordinator.isCancelling ? "正在取消…" : "取消") { coordinator.cancel() }.disabled(coordinator.isCancelling)
                } else {
                    Button("识别图片文字") { coordinator.start() }.buttonStyle(.borderedProminent)
                }
            }
            Text("Apple Vision 在这台 Mac 上逐张识别，不调用模型或网络。识别结果仅用于搜索，原图片与正文保持不变。")
                .font(.caption).foregroundStyle(JournalTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if coordinator.isRunning {
                if coordinator.progress.total > 0 {
                    ProgressView(value: Double(coordinator.progress.completed), total: Double(coordinator.progress.total))
                    Text(coordinator.progress.name).font(.caption).foregroundStyle(JournalTheme.secondary).lineLimit(1)
                } else { ProgressView().controlSize(.small) }
            }
            Text(coordinator.status).font(.caption).foregroundStyle(JournalTheme.secondary)
            if !coordinator.errors.isEmpty {
                DisclosureGroup("\(coordinator.errors.count) 项识别问题") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(coordinator.errors.enumerated()), id: \.offset) { _, message in
                                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 160)
                }
            }
        }.journalCard(padding: 18)
    }
}
