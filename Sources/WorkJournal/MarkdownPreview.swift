import SwiftUI
import JournalCore

struct MarkdownPreview: View {
    let source: String
    var provenance: ReportProvenance? = nil
    @ViewState private var displayedSources: SourcePresentation?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let provenance {
                    HStack {
                        Button { displayedSources = SourcePresentation(title: "生成时的全部素材", sources: provenance.sources) } label: { Label("查看生成素材（\(provenance.sources.count)）", systemImage: "doc.text.magnifyingglass") }
                        Spacer()
                    }
                    Text(source == provenance.generatedText ? "要点旁可查看模型标注的来源；未标注的要点请核对全部素材。" : "正文已修改，原要点对应关系已停用；仍可查看生成时的素材。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
                ForEach(Array(MarkdownBlocks.parse(source).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }.frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity).padding(6).textSelection(.enabled)
        }.accessibilityLabel("日报排版预览")
        .sheet(item: $displayedSources) { item in ReportSourcesView(title: item.title, sources: item.sources) }
    }
    private func inline(_ text: String) -> Text {
        let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(parsed ?? AttributedString(text))
    }
    @ViewBuilder private func blockView(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text).font(.system(size: level == 1 ? 25 : level == 2 ? 20 : 16, weight: .semibold))
                .padding(.top, level == 1 ? 4 : 10).accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            inline(text).font(.system(size: 14)).lineSpacing(6)
        case let .item(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker).foregroundStyle(JournalTheme.accent).frame(minWidth: 16, alignment: .trailing)
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
                if let provenance {
                    let sources = provenance.sources(forPoint: text, currentText: source)
                    if !sources.isEmpty {
                        Button { displayedSources = SourcePresentation(title: "模型标注的来源，请核对", sources: sources) } label: { Image(systemName: "link.circle") }.buttonStyle(.plain).foregroundStyle(JournalTheme.accent).help("查看此要点来源").accessibilityLabel("查看此要点来源")
                    }
                }
            }.font(.system(size: 14)).lineSpacing(5).padding(.leading, 4)
        case let .quote(text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(JournalTheme.accent.opacity(0.5)).frame(width: 3)
                inline(text).font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true).padding(10).background(JournalTheme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        case let .code(text):
            ScrollView(.horizontal) {
                Text(verbatim: text).font(.system(size: 12, design: .monospaced)).padding(12)
            }.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        case let .table(table):
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    tableRow(table.headers, alignments: table.alignments, header: true)
                        .background(JournalTheme.soft)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                        Divider().overlay(JournalTheme.border)
                        tableRow(row, alignments: table.alignments, header: false)
                            .background(index.isMultiple(of: 2) ? JournalTheme.paper : JournalTheme.Tone.neutral.surface.opacity(0.35))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(JournalTheme.border))
                    .padding(.bottom, 6)
            }
        case .divider:
            Divider().padding(.vertical, 6)
        }
    }
    private func tableRow(_ cells: [String], alignments: [MarkdownBlocks.Alignment], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let alignment: Alignment = alignments[index] == .right ? .trailing : alignments[index] == .center ? .center : .leading
                inline(cell).font(.system(size: 13, weight: header ? .semibold : .regular)).lineSpacing(4)
                    .multilineTextAlignment(alignments[index] == .right ? .trailing : alignments[index] == .center ? .center : .leading)
                    .frame(width: 176, alignment: alignment).padding(12)
            }
        }
    }
}
