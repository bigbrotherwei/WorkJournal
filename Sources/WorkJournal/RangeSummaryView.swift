import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JournalCore

struct RangeSummaryView: View {
    @ObservedObject var app: AppModel
    @ViewState private var start = Date()
    @ViewState private var end = Date()
    @ViewState private var includeAll = false
    @ViewState private var drafts: [String: RangeSummary] = [:]
    @ViewState private var preview = true
    @ViewState private var feedback = ""
    @ViewState private var replacePrompt = false
    @ViewState private var startCalendar = false
    @ViewState private var endCalendar = false
    @ViewState private var showingHistory = false
    private var range: SummaryRange? { try? SummaryRange(startDay: Days.key(start), endDay: Days.key(end)) }
    private var key: String { "\(Days.key(start))_\(Days.key(end))_\(includeAll)" }
    private var candidate: RangeSummary? { drafts[key] }
    private var text: Binding<String> {
        Binding(get: { candidate?.text ?? "" }, set: { value in
            guard let range else { return }
            var draft = drafts[key] ?? RangeSummary(startDay: range.startDay, endDay: range.endDay, text: "", sourceFingerprint: RangeSummaryGenerator.sourceFingerprint(range: range, entries: app.entries, includeAllRecords: includeAll), includeAllRecords: includeAll)
            draft.text = value; drafts[key] = draft; persist()
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                PageHeading(title: "周报", subtitle: "选择本周、上周或自选日期范围，归纳跨日工作。图片不参与。")
                Spacer()
                Button { showingHistory = true } label: { Label("历史周报", systemImage: "clock.arrow.circlepath") }
                    .disabled(app.busy)
            }
            HStack {
                Button("本周") { select(.currentWeek()) }
                Button("上周") { select(.previousWeek()) }
                dateControl("开始", date: $start, showing: $startCalendar)
                dateControl("结束", date: $end, showing: $endCalendar)
            }.disabled(app.busy)
            HStack {
                Toggle("包含全部记录", isOn: $includeAll).toggleStyle(.checkbox).disabled(app.busy)
                Text(includeAll ? "包含范围内全部未删除记录" : "仅使用已勾选“计入日报”的记录").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if app.busy { Button("取消", action: app.cancel) }
                Button("生成周报") {
                    if !(candidate?.text ?? "").isEmpty { replacePrompt = true } else { generate() }
                }.disabled(app.busy || range == nil)
            }
            if range == nil { Text("结束日期不能早于开始日期。").foregroundStyle(.red) }
            HStack {
                Text(range?.title ?? "无效日期范围").font(.headline)
                Spacer()
                Toggle("预览", isOn: $preview).toggleStyle(.switch)
                Menu("历史版本") {
                    if let range {
                        ForEach(app.summaryVersions(range: range).filter { $0.includeAllRecords == includeAll }) { version in
                            Button(version.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                                // Keep current edits in a recovery slot before loading an older version.
                                if let current = candidate { archive(current) }
                                drafts[key] = version; persist(); feedback = "已载入历史版本；原编辑仍保留在恢复草稿中。"
                            }
                        }
                    }
                    Menu("恢复编辑草稿") {
                        ForEach(drafts.filter { $0.key.hasPrefix("recovery_") }.map(\.value).sorted { $0.createdAt > $1.createdAt }) { draft in
                            Button("\(draft.startDay) — \(draft.endDay) · \(draft.createdAt.formatted())") {
                                if let range = try? SummaryRange(startDay: draft.startDay, endDay: draft.endDay) { select(range); includeAll = draft.includeAllRecords; if let current = drafts[key] { archive(current) }; drafts[key] = draft; persist() }
                            }
                        }
                    }
                }
            }
            if preview {
                MarkdownPreview(source: candidate?.text ?? "尚未生成周报")
            } else {
                TextEditor(text: text).font(.system(.body, design: .monospaced)).accessibilityLabel("周报编辑内容")
            }
            Text("编辑草稿自动保留；切换日期后返回可继续编辑。保存会创建独立新版本。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(candidate?.text ?? "", forType: .string); feedback = "已复制" }.disabled(candidate?.text.isEmpty != false)
                Button("导出 Markdown", action: export).disabled(candidate?.text.isEmpty != false)
                Button("保存新版本") {
                    guard var summary = candidate else { return }
                    summary.id = UUID(); summary.createdAt = Date()
                    if app.saveSummary(summary) { drafts[key] = summary; persist(); feedback = "已保存新版本" }
                }.disabled(app.busy || candidate?.text.isEmpty != false)
            }
        }.padding(24)
        .onAppear { restore(); select(.currentWeek()); loadLatest() }
        .onChange(of: key) { _, _ in loadLatest() }
        .sheet(isPresented: $showingHistory) {
            SummaryHistoryView(app: app, drafts: drafts, select: openHistory)
        }
        .confirmationDialog("重新生成将替换当前编辑；当前内容会保留到恢复草稿。", isPresented: $replacePrompt) {
            Button("保留草稿并重新生成") { if let current = candidate { archive(current); persist() }; generate() }
            Button("取消", role: .cancel) {}
        }
    }
    private func openHistory(_ item: SummaryHistoryItem) {
        let summary = item.summary
        guard let selectedRange = try? SummaryRange(startDay: summary.startDay, endDay: summary.endDay) else { return }
        let destination = "\(summary.startDay)_\(summary.endDay)_\(summary.includeAllRecords)"
        var preservedEdits = false
        if let edited = drafts[destination], edited != summary, !edited.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            archive(edited); preservedEdits = true
        }
        drafts[destination] = summary
        select(selectedRange); includeAll = summary.includeAllRecords; preview = true
        persist()
        feedback = (item.isDraft ? "已打开未保存草稿" : "已打开历史周报") + (preservedEdits ? "；原编辑已保留在“历史版本 → 恢复编辑草稿”中。" : "")
    }
    private func dateControl(_ label: String, date: Binding<Date>, showing: Binding<Bool>) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button { date.wrappedValue = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: date.wrappedValue)! } label: { Image(systemName: "chevron.left") }.accessibilityLabel("\(label)前一天")
            Button { showing.wrappedValue = true } label: { Label(Days.key(date.wrappedValue), systemImage: "calendar") }
                .popover(isPresented: showing) {
                    DatePicker(label, selection: Binding(get: { date.wrappedValue }, set: { date.wrappedValue = $0; showing.wrappedValue = false }), displayedComponents: .date).datePickerStyle(.graphical).padding(16)
                }
            Button { date.wrappedValue = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: date.wrappedValue)! } label: { Image(systemName: "chevron.right") }.accessibilityLabel("\(label)后一天")
        }
    }
    private func archive(_ summary: RangeSummary) {
        var copy = summary; copy.id = UUID(); copy.createdAt = Date()
        drafts["recovery_\(copy.id)"] = copy
    }
    private func loadLatest() {
        guard drafts[key] == nil, let range, let saved = app.summaryVersions(range: range).filter({ $0.includeAllRecords == includeAll }).sorted(by: { $0.createdAt > $1.createdAt }).first else { return }
        drafts[key] = saved
    }
    private func select(_ range: SummaryRange) {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        if let value = f.date(from: range.startDay) { start = value }
        if let value = f.date(from: range.endDay) { end = value }
    }
    private func generate() {
        guard let range else { return }
        let destination = key
        app.generateSummary(range: range, includeAllRecords: includeAll) { summary in
            if let edited = drafts[destination] { archive(edited) }
            drafts[destination] = summary; persist(); feedback = "已生成，可编辑后保存"
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(drafts) { UserDefaults.standard.set(data, forKey: "rangeSummaryEditingDrafts") }
    }
    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: "rangeSummaryEditingDrafts"), let saved = try? JSONDecoder().decode([String: RangeSummary].self, from: data) else { return }
        drafts = saved
    }
    private func export() {
        guard let summary = candidate else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(summary.startDay)_\(summary.endDay).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try summary.text.write(to: url, atomically: true, encoding: .utf8); feedback = "已导出" } catch { app.error = error.localizedDescription }
    }
}
