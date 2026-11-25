import SwiftUI
import Combine
import JournalCore

struct UnifiedSearchView: View {
    let input: UnifiedSearchInput
    var ocrCoordinator: LocalOCRCoordinator?
    let openResult: (UnifiedSearchResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = UnifiedSearchSession()
    @ViewState private var text = ""
    @ViewState private var kind: UnifiedSearchKind?
    @ViewState private var folderID: UUID?
    @ViewState private var usesStartDate = false
    @ViewState private var usesEndDate = false
    @ViewState private var startDate = Date()
    @ViewState private var endDate = Date()
    @FocusState private var searchFocused: Bool

    init(input: UnifiedSearchInput, ocrCoordinator: LocalOCRCoordinator? = nil, openResult: @escaping (UnifiedSearchResult) -> Void) {
        self.input = input; self.ocrCoordinator = ocrCoordinator; self.openResult = openResult
    }
    private var query: UnifiedSearchQuery {
        UnifiedSearchQuery(text: text, kinds: kind.map { [$0] } ?? [], startDay: usesStartDate ? Days.key(startDate) : nil, endDay: usesEndDate ? Days.key(endDate) : nil, folderID: folderID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                JournalSymbol(name: "magnifyingglass", tone: .violet)
                VStack(alignment: .leading, spacing: 3) {
                    Text("搜索全部内容").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("记录、待办、日报版本、周报和笔记").font(.caption).foregroundStyle(JournalTheme.secondary)
                }
                Spacer()
                Button("关闭") { session.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(JournalTheme.secondary)
                TextField("搜索标题、正文或已识别的图片文字", text: $text)
                    .textFieldStyle(.plain).focused($searchFocused)
                if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
            }.padding(13).background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(JournalTheme.border))
            filters
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if usesStartDate && usesEndDate && Days.key(startDate) > Days.key(endDate) {
                Label("开始日期不能晚于结束日期", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if session.isSearching {
                HStack { ProgressView().controlSize(.small); Text("正在搜索…").font(.caption).foregroundStyle(JournalTheme.secondary) }
                Spacer()
            } else if session.results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: text.isEmpty && !query.hasFilters ? "doc.text.magnifyingglass" : "magnifyingglass").font(.system(size: 32)).foregroundStyle(JournalTheme.accent)
                    Text(text.isEmpty && !query.hasFilters ? "输入关键词，或选择筛选条件" : "没有找到匹配内容").foregroundStyle(JournalTheme.secondary)
                    Text("回收站内容不会参与搜索。笔记按修改日期筛选，范围总结按日期区间匹配。").font(.caption).foregroundStyle(JournalTheme.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("找到 \(session.results.count) 项").font(.caption).foregroundStyle(JournalTheme.secondary)
                    Spacer()
                    Text("按类型分组 · 日期从近到远").font(.caption).foregroundStyle(JournalTheme.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(UnifiedSearchKind.allCases, id: \.self) { kind in
                            let rows = session.results.filter { $0.kind == kind }
                            if !rows.isEmpty {
                                Label("\(kind.title) · \(rows.count)", systemImage: kind.symbol).font(.headline).foregroundStyle(JournalTheme.ink).padding(.top, 4)
                                ForEach(rows) { result in resultRow(result) }
                            }
                        }
                    }.padding(.bottom, 12)
                }
            }
        }
        .padding(24).frame(minWidth: 720, idealWidth: 830, minHeight: 560, idealHeight: 700)
        .background(JournalPageBackground())
        .onAppear { searchFocused = true; search() }
        .onChange(of: query) { _, _ in search() }
        .onChange(of: input) { _, _ in search() }
        .onReceive(ocrCoordinator?.$revision.dropFirst().eraseToAnyPublisher() ?? Empty<Int, Never>().eraseToAnyPublisher()) { _ in search() }
        .onDisappear { session.cancel() }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("类型", selection: $kind) {
                    Text("全部类型").tag(Optional<UnifiedSearchKind>.none)
                    ForEach(UnifiedSearchKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.frame(maxWidth: 240)
                Picker("笔记目录", selection: $folderID) {
                    Text("全部目录").tag(Optional<UUID>.none)
                    ForEach(input.folders.filter { $0.deletedAt == nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                        Text($0.name).tag(Optional($0.id))
                    }
                }.frame(maxWidth: 280)
                Spacer(minLength: 0)
                if query.hasFilters { Button("重置筛选") { kind = nil; folderID = nil; usesStartDate = false; usesEndDate = false }.font(.caption) }
            }
            HStack(spacing: 10) {
                Toggle("开始日期", isOn: $usesStartDate).toggleStyle(.checkbox)
                if usesStartDate { DatePicker("", selection: $startDate, displayedComponents: .date).labelsHidden().frame(width: 115) }
                Toggle("结束日期", isOn: $usesEndDate).toggleStyle(.checkbox)
                if usesEndDate { DatePicker("", selection: $endDate, displayedComponents: .date).labelsHidden().frame(width: 115) }
                Spacer(minLength: 0)
                if folderID != nil { Text("仅笔记 · 含子目录").font(.caption).foregroundStyle(JournalTheme.secondary) }
            }.font(.caption)
        }
    }
    private func resultRow(_ result: UnifiedSearchResult) -> some View {
        Button {
            session.cancel(); dismiss(); openResult(result)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(result.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(JournalTheme.ink).lineLimit(1)
                    Spacer()
                    if result.isOCRMatch { Label("图片文字", systemImage: "text.viewfinder").font(.caption2).foregroundStyle(JournalTheme.accent) }
                    Text(result.day == result.endDay ? result.day : result.day + " — " + result.endDay).font(.caption).foregroundStyle(JournalTheme.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(JournalTheme.secondary)
                }
                Text(highlight(result.snippet, query: result.query)).font(.system(size: 12)).foregroundStyle(JournalTheme.secondary).lineLimit(3).multilineTextAlignment(.leading)
            }.frame(maxWidth: .infinity, alignment: .leading).journalCard(padding: 14)
        }.buttonStyle(.plain)
    }
    private func highlight(_ snippet: String, query: String) -> AttributedString {
        var text = AttributedString(snippet)
        if !query.isEmpty, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].foregroundColor = JournalTheme.accent
            text[range].font = .system(size: 12, weight: .semibold)
        }
        return text
    }
    private func search() {
        if let coordinator = ocrCoordinator { session.submit(query, in: input, loadOCR: { try await coordinator.validatedTexts() }) }
        else { session.submit(query, in: input) }
    }
}
