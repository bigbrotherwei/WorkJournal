import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JournalCore

struct ReportExportView: View {
    @ObservedObject var app: AppModel
    let initialDate: Date
    @Environment(\.dismiss) private var dismiss
    @ViewState private var month = Date()
    @ViewState private var rows: [ReportArchiveDay] = []
    @ViewState private var selected: Set<String> = []
    @ViewState private var failure: String?
    @ViewState private var feedback = ""
    private var calendar: Calendar { Calendar(identifier: .gregorian) }
    private var available: Set<String> { Set(rows.filter { $0.latestReport != nil }.map(\.day)) }
    private var markdown: String { ReportMarkdownExport.render(rows: rows, selectedDays: selected) }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: month)!.start }
    private var monthDays: [Date] {
        (calendar.range(of: .day, in: .month, for: month) ?? 1..<1).compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: monthStart)
        }
    }
    private var offset: Int { (calendar.component(.weekday, from: monthStart) + 5) % 7 }
    private var monthTitle: String {
        let parts = calendar.dateComponents([.year, .month], from: month)
        return "\(parts.year!) 年 \(parts.month!) 月"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                PageHeading(title: "导出日报", subtitle: "多选日期，合并为 Markdown。每一天取最新保存的版本。")
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Label("未保存的编辑内容不会导出，请先在日报页保存新版本。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                // Keep six-week months and long selections inside the card, not the sheet.
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上个月")
                        Spacer()
                        Text(monthTitle).font(.headline)
                        Spacer()
                        Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下个月")
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                        ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 30) }
                        ForEach(monthDays, id: \.self) { date in dayButton(date) }
                    }
                    HStack {
                        Button("选择本月") { selected.formUnion(monthDays.map { Days.key($0) }.filter { available.contains($0) }) }
                            .disabled(!monthDays.contains { available.contains(Days.key($0)) })
                        Button("清空") { selected.removeAll() }.disabled(selected.isEmpty)
                        Spacer()
                        Button("本月") { month = Date() }
                    }.font(.caption)
                    Label("有日报的日期可选，支持跨月多选", systemImage: "calendar.badge.checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("已选 \(selected.count) 天").font(.headline)
                    if available.isEmpty && failure == nil {
                        Text("暂无已保存的日报。先保存一份日报，再来导出。") .font(.callout).foregroundStyle(.secondary)
                    }
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(selected.sorted(), id: \.self) { day in
                                HStack {
                                    Text(day).font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    Button { selected.remove(day) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).accessibilityLabel("取消选择 \(day)")
                                }
                            }
                        }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                }.frame(width: 290).frame(maxHeight: .infinity).journalCard()
                VStack(alignment: .leading, spacing: 12) {
                    Label("Markdown 预览", systemImage: "doc.plaintext").font(.headline)
                    if markdown.isEmpty {
                        ContentUnavailableView("选择要导出的日期", systemImage: "calendar", description: Text("选中后会在这里显示可复制的 Markdown 内容。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(markdown).font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(8)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("Markdown 导出内容（只读）")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).journalCard()
            }.frame(minHeight: 0, maxHeight: .infinity)
            if let failure { HStack { Text(failure).foregroundStyle(.red).textSelection(.enabled); Button("重新读取", action: reload) } }
            HStack {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { copy() } label: { Label("复制全部", systemImage: "doc.on.doc") }.disabled(markdown.isEmpty)
                Button { saveFile() } label: { Label("保存为 .md 文件", systemImage: "square.and.arrow.down") }
                    .buttonStyle(JournalPrimaryButtonStyle()).disabled(markdown.isEmpty)
            }
        }.padding(24).frame(width: 880, height: 640).background(JournalTheme.canvas).tint(JournalTheme.accent).buttonStyle(JournalSecondaryButtonStyle())
            .onAppear { month = initialDate; reload() }
            .onChange(of: selected) { _, _ in feedback = "" }
    }
    private func dayButton(_ date: Date) -> some View {
        let day = Days.key(date)
        let enabled = available.contains(day)
        let chosen = selected.contains(day)
        return Button {
            if chosen { selected.remove(day) } else { selected.insert(day) }
        } label: {
            Text("\(calendar.component(.day, from: date))").font(.system(size: 13, weight: enabled ? .semibold : .regular))
                .frame(maxWidth: .infinity).frame(height: 30)
                .foregroundStyle(chosen ? Color.white : enabled ? JournalTheme.accent : Color.secondary.opacity(0.5))
                .background(chosen ? JournalTheme.accentFill : enabled ? JournalTheme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel("\(day)，\(enabled ? (chosen ? "已选择" : "有日报") : "无已保存日报")")
    }
    private func moveMonth(_ amount: Int) {
        if let next = calendar.date(byAdding: .month, value: amount, to: monthStart) { month = next }
    }
    private func reload() {
        do { rows = try app.reportArchive(); selected.formIntersection(available); failure = nil }
        catch { rows = []; selected = []; failure = error.localizedDescription }
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        feedback = NSPasteboard.general.setString(markdown, forType: .string) ? "已复制 \(selected.count) 天日报" : "复制失败，请重试"
    }
    private func saveFile() {
        let content = markdown
        guard !content.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "日报-\(selected.sorted().first!)-\(selected.sorted().last!).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try content.write(to: url, atomically: true, encoding: .utf8); feedback = "已保存：\(url.lastPathComponent)"; failure = nil }
        catch { failure = "保存失败：\(error.localizedDescription)" }
    }
}
