import SwiftUI
import AppKit
import JournalCore

private actor SearchSnapshotReader {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> UnifiedSearchInput {
        try Task.checkCancellation()
        return try JournalStore(url: url).unifiedSearchInput()
    }
}

struct GlobalSearchHost: View {
    @ObservedObject var app: AppModel
    let openResult: (UnifiedSearchResult) -> Void
    @ObservedObject private var notebook: NotebookModel
    init(app: AppModel, openResult: @escaping (UnifiedSearchResult) -> Void) {
        self.app = app; self.openResult = openResult; self.notebook = app.notebook
    }
    private var refreshKey: [String] {
        app.entries.map { $0.id.uuidString + String($0.updatedAt.timeIntervalSinceReferenceDate) } + notebook.notes.map { $0.id.uuidString + String($0.revision) } + notebook.folders.map { $0.id.uuidString + String($0.updatedAt.timeIntervalSinceReferenceDate) }
    }
    @ViewState private var input: UnifiedSearchInput?
    @ViewState private var failure: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let input {
                UnifiedSearchView(input: input, ocrCoordinator: app.ocrCoordinator, openResult: openResult)
            } else {
                VStack(spacing: 20) {
                    if let failure { Text(failure).foregroundStyle(.secondary); Button("关闭") { dismiss() } }
                    else { ProgressView(); Text("正在准备本机搜索…").foregroundStyle(.secondary) }
                }.frame(width: 800, height: 580).background(JournalPageBackground())
            }
        }.task(id: refreshKey) {
            do {
                try await app.notebook.flush()
                guard let url = app.databaseURL else { throw JournalError.invalid("数据目录尚未就绪") }
                let snapshot = try await SearchSnapshotReader(url: url).load()
                try Task.checkCancellation()
                input = snapshot
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}

struct SearchReportPreview: Identifiable {
    let id: UUID
    let title: String
    let text: String
    let provenance: ReportProvenance?
    let savedAt: Date
}

struct SearchReportPreviewView: View {
    let report: SearchReportPreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageHeading(title: report.title, subtitle: "已保存版本 · " + report.savedAt.formatted(date: .abbreviated, time: .standard))
                Spacer(); Button("完成") { dismiss() }
            }
            MarkdownPreview(source: report.text, provenance: report.provenance).journalCard(padding: 20)
            HStack { Text("这里展示命中的已保存版本，草稿保留在原页面。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("复制 Markdown") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.text, forType: .string) } }
        }.padding(24).frame(width: 760, height: 600).background(JournalPageBackground()).buttonStyle(JournalSecondaryButtonStyle())
    }
}
