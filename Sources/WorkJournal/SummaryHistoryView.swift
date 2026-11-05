import SwiftUI
import JournalCore

struct SummaryHistoryView: View {
    @ObservedObject var app: AppModel
    let drafts: [String: RangeSummary]
    let select: (SummaryHistoryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var rows: [SummaryHistoryItem] = []
    @ViewState private var query = ""
    @ViewState private var failure: String?

    private var filtered: [SummaryHistoryItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { term.isEmpty || "\($0.summary.startDay) \($0.summary.endDay) \($0.summary.text)".localizedStandardContains(term) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("历史周报", systemImage: "clock.arrow.circlepath").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("所有日期范围的已保存版本与未保存草稿，按日期从近到远排列。点击即可打开。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("搜索日期、月份或周报内容", text: $query).textFieldStyle(.roundedBorder)
            if let failure {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
                Button("重试", action: reload)
                Spacer()
            } else if rows.isEmpty {
                ContentUnavailableView("暂无历史周报", systemImage: "doc.text", description: Text("生成或保存周报后，会在这里显示；自选时间范围也会收录。"))
            } else if filtered.isEmpty {
                ContentUnavailableView("没有找到匹配的周报", systemImage: "magnifyingglass", description: Text("试试其他日期或关键词。"))
            } else {
                Text("\(filtered.count) 条记录 · 已保存 \(filtered.filter { !$0.isDraft }.count) 个版本 · 草稿 \(filtered.filter(\.isDraft).count) 份")
                    .font(.caption).foregroundStyle(.secondary)
                List(filtered) { row in
                    Button {
                        select(row); dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: row.isDraft ? "square.and.pencil" : "doc.text")
                                .font(.title2).foregroundStyle(row.isDraft ? Color.orange : Color.accentColor)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(row.summary.startDay == row.summary.endDay ? row.summary.startDay : "\(row.summary.startDay) — \(row.summary.endDay)")
                                        .font(.headline.monospacedDigit())
                                    Text(row.isDraft ? "草稿" : "已保存").font(.caption)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background((row.isDraft ? Color.orange : Color.accentColor).opacity(0.12), in: Capsule())
                                }
                                Text("\(row.summary.includeAllRecords ? "全部记录" : "日报素材") · \(row.isDraft ? "创建于" : "保存于") \(row.summary.createdAt.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(row.summary.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(24).frame(width: 720, height: 540).onAppear(perform: reload)
    }
    private func reload() {
        do { rows = try app.summaryHistory(drafts: drafts); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
