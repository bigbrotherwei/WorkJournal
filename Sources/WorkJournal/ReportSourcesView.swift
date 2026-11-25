import SwiftUI
import JournalCore

struct SourcePresentation: Identifiable {
    let id = UUID()
    let title: String
    let sources: [ReportSourceSnapshot]
}

struct ReportSourcesView: View {
    let title: String
    let sources: [ReportSourceSnapshot]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { PageHeading(title: title, subtitle: "保留的是生成时的文字快照，不随原记录修改或删除而变化。"); Spacer(); Button("完成") { dismiss() } }
            sourceCards(sources)
        }.padding(24).frame(width: 660, height: 560).background(JournalPageBackground())
            .buttonStyle(JournalSecondaryButtonStyle())
    }
}

struct ReportMaterialsView: View {
    let entries: [Entry]
    let startDay: String
    let endDay: String
    let includeAll: Bool
    @Environment(\.dismiss) private var dismiss
    private var inRange: [Entry] { entries.filter { $0.deletedAt == nil && $0.day >= startDay && $0.day <= endDay } }
    private var selected: [Entry] { inRange.filter { (includeAll || $0.inReport) && !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { PageHeading(title: "本次总结素材", subtitle: startDay == endDay ? startDay : "\(startDay) — \(endDay)"); Spacer(); Button("完成") { dismiss() } }
            HStack(spacing: 16) {
                Label("\(selected.count) 条文字素材", systemImage: "doc.on.doc")
                Text("\(selected.filter { $0.category == "未分类" }.count) 条未分类")
                if !includeAll { Text("\(inRange.filter { !$0.inReport }.count) 条未计入") }
            }.font(.callout).foregroundStyle(.secondary)
            Text("仅总结文字；图片不会自动交给模型识别。未计入的记录可回到记录页勾选。生成前可核对是否有遗漏。").font(.caption).foregroundStyle(.secondary)
            sourceCards(selected.sorted { $0.createdAt < $1.createdAt }.map(ReportSourceSnapshot.init))
        }.padding(24).frame(width: 660, height: 560).background(JournalPageBackground())
            .buttonStyle(JournalSecondaryButtonStyle())
    }
}

private func sourceCards(_ sources: [ReportSourceSnapshot]) -> some View {
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
            if sources.isEmpty { Text("暂无可用文字素材").foregroundStyle(.secondary).padding(24) }
            ForEach(sources) { source in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(source.day); Text(source.category); Spacer(); Text(source.status) }.font(.caption).foregroundStyle(.secondary)
                    Text(source.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.journalCard(padding: 16)
            }
        }.padding(2)
    }
}
