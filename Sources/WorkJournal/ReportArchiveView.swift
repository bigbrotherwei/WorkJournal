import SwiftUI
import JournalCore

struct ReportArchiveView: View {
    @ObservedObject var app: AppModel
    var select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var rows: [ReportArchiveDay] = []
    @ViewState private var query = ""
    @ViewState private var onlyUnsaved = false
    @ViewState private var failure: String?
    private var filtered: [ReportArchiveDay] {
        rows.filter { (query.isEmpty || $0.day.contains(query.trimmingCharacters(in: .whitespacesAndNewlines))) && (!onlyUnsaved || $0.state == .unsaved) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("日报归档").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
            }
            Text("按归属日期回顾已保存日报和待整理素材；编辑中的草稿不计入已保存版本。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("搜索日期或月份，如 2026-10", text: $query).textFieldStyle(.roundedBorder)
                Toggle("仅尚未保存", isOn: $onlyUnsaved).toggleStyle(.checkbox)
            }
            if let failure {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
                Button("重试", action: reload)
                Spacer()
            } else if filtered.isEmpty {
                ContentUnavailableView("暂无符合条件的日期", systemImage: "calendar", description: Text("保存日报或勾选“计入日报”的记录后，会在这里显示。"))
            } else {
                List(filtered) { row in
                    Button {
                        select(row.day)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.day).font(.headline.monospacedDigit())
                                Text("\(row.sourceCount) 条素材 · \(row.versionCount) 个已保存版本").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(row.state.rawValue).font(.callout)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(24).frame(width: 640, height: 500).onAppear(perform: reload)
    }
    private func reload() {
        do { rows = try app.reportArchive(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
