import SwiftUI
import AppKit
import JournalCore

struct RecordsPageView: View {
    @ObservedObject var app: AppModel
    let capture: () -> Void
    let openSettings: () -> Void
    @ViewState private var query = ""
    @ViewState private var category = "全部"
    @ViewState private var status = "全部"
    @ViewState private var scope: RecordScope = .all
    @ViewState private var activityDay: String?
    @ViewState private var detail: Entry?
    @ViewState private var editing: Entry?
    @AppStorage("recordActivityExpanded") private var activityExpanded = false
    private var filtered: [Entry] {
        let today = Days.key(Date())
        return app.entries.filter {
            scope.includes($0, today: today) && (activityDay == nil || $0.day == activityDay) &&
            (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.day.contains(query)) &&
            (category == "全部" || $0.category == category) && (status == "全部" || $0.status.rawValue == status)
        }
    }
    private var isFiltered: Bool { scope != .all || activityDay != nil || !query.isEmpty || category != "全部" || status != "全部" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    PageHeading(title: "记录", subtitle: Date().formatted(.dateTime.month(.wide).day().weekday(.wide)))
                    Spacer(minLength: 16)
                    Button("整理未分类", action: app.classifyPending).disabled(app.busy || app.checkingModels || app.model.isEmpty)
                    Button(action: capture) { Label("记一笔", systemImage: "plus") }.buttonStyle(JournalPrimaryButtonStyle())
                }
                metrics
                DisclosureGroup(isExpanded: $activityExpanded) {
                    RecordActivityView(entries: app.entries, selectedDay: activityDay) { day in
                        activityDay = activityDay == day ? nil : day
                        scope = .all; query = ""; category = "全部"; status = "全部"
                    }.padding(.top, 10)
                } label: {
                    HStack {
                        Label("记录总览", systemImage: "chart.bar.xaxis").font(.system(size: 12, weight: .medium))
                        Text("最近 12 周").font(.caption).foregroundStyle(.secondary)
                    }
                }.tint(JournalTheme.accent)
                if app.model.isEmpty {
                    HStack {
                        Label("本地 AI 尚未配置，仍可记录和手动分类", systemImage: "sparkles")
                        Spacer(); Button("设置本地 AI", action: openSettings)
                    }.font(.caption).padding(12).background(JournalTheme.soft, in: RoundedRectangle(cornerRadius: 13))
                }
                filters
                HStack {
                    Text("\(activityDay ?? scope.rawValue) · \(filtered.count) 条记录").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if isFiltered { Button("查看全部", action: reset) }
                    if app.canUndo { Button("撤销删除", action: app.undoDelete) }
                }
                if filtered.isEmpty {
                    JournalEmptyState(filtered: isFiltered, capture: capture, reset: reset)
                } else {
                    let days = Array(Set(filtered.map(\.day))).sorted(by: >)
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Circle().fill(JournalTheme.accent.opacity(0.45)).frame(width: 7, height: 7)
                                Text(day == Days.key(Date()) ? "今天" : day).font(.system(size: 13, weight: .semibold))
                                Text(day == Days.key(Date()) ? day : "\(filtered.filter { $0.day == day }.count) 条记录")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                                ForEach(filtered.filter { $0.day == day }) { entry in
                                    RecordCard(app: app, entry: entry, open: { detail = entry }, edit: { editing = entry })
                                }
                            }
                        }
                    }
                }
            }.padding(26).frame(maxWidth: 1160).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: app.categories) { _, names in if category != "全部" && !names.contains(category) { category = "全部" } }
        .sheet(item: $detail) { RecordDetailView(app: app, entryID: $0.id) }
        .sheet(item: $editing) { EntryEditor(app: app, entry: $0) }
    }
    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { metricButtons }
            VStack(alignment: .leading, spacing: 6) { metricButtons }
        }
    }
    @ViewBuilder private var metricButtons: some View {
        ForEach([RecordScope.all, .today, .pending, .report], id: \.self) { item in
            Button {
                scope = scope == item ? .all : item; activityDay = nil; query = ""; category = "全部"; status = "全部"
            } label: {
                JournalMetric(title: item.rawValue, value: app.entries.filter { item.includes($0, today: Days.key(Date())) }.count, icon: item.icon)
                    .foregroundStyle(scope == item ? JournalTheme.accent : JournalTheme.secondary)
                    .background(scope == item ? JournalTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel("查看" + item.rawValue)
                .accessibilityValue(scope == item ? "已选中" : "未选中")
        }
    }
    private var filters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索记录、关键词或日期", text: $query).textFieldStyle(.plain)
            }.padding(11).background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(JournalTheme.border))
            Picker("分类", selection: $category) {
                Text("全部").tag("全部"); ForEach(app.categories, id: \.self) { Text($0).tag($0) }
            }.frame(width: 145)
            Picker("状态", selection: $status) {
                Text("全部").tag("全部"); ForEach(FollowUp.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }.frame(width: 125)
        }
    }
    private func reset() { query = ""; category = "全部"; status = "全部"; scope = .all; activityDay = nil }
}

private struct RecordCard: View {
    @ObservedObject var app: AppModel
    let entry: Entry
    let open: () -> Void
    let edit: () -> Void
    @ViewState private var hovering = false
    @ViewState private var imagePreview: ImageAttachment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var style: (symbol: String, tone: JournalTheme.Tone) { JournalTheme.category(entry.category) }
    private var lines: [String] { entry.plainText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 9) {
                        JournalSymbol(name: style.symbol, tone: style.tone, size: 37)
                        Text(entry.category).font(.system(size: 12, weight: .medium)).foregroundStyle(style.tone.color)
                        Spacer(minLength: 0)
                    }
                    Text(lines.first ?? "图片记录").font(.system(size: 15, weight: .semibold)).foregroundStyle(JournalTheme.ink).lineLimit(2)
                    if lines.count > 1 {
                        Text(lines.dropFirst().joined(separator: " ")).font(.system(size: 13)).lineSpacing(5)
                            .foregroundStyle(.secondary).lineLimit(3)
                    }
                }.frame(maxWidth: .infinity, minHeight: 114, alignment: .topLeading).padding(20).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("打开记录：" + (lines.first ?? "图片记录"))
            if !entry.images.isEmpty {
                ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(entry.images) { item in
                        if let image = NSImage(data: item.data) {
                            Button { imagePreview = item } label: {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 55, height: 42)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).accessibilityLabel("查看图片：" + item.name)
                        }
                    }
                }.padding(.horizontal, 20)
                }.padding(.bottom, 12)
            }
            HStack(spacing: 7) {
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption)
                if entry.inReport { Image(systemName: "doc.text").help("日报素材").accessibilityLabel("日报素材") }
                Spacer(minLength: 0)
                FollowUpMenu(app: app, entry: entry)
                Menu {
                    Button("查看详情", action: open)
                    Button("编辑记录", action: edit)
                    Divider()
                    Button("移入回收站", role: .destructive) { app.delete(entry) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("记录更多操作")
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 16)
            if let due = entry.dueAt {
                Label("截止 " + due.formatted(date: .abbreviated, time: .shortened), systemImage: entry.reminderEnabled ? "bell" : "calendar")
                    .font(.caption).foregroundStyle(entry.status == .pending && due < Date() ? Color.orange : JournalTheme.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .background(LinearGradient(colors: [style.tone.surface, JournalTheme.paper, JournalTheme.paper], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(hovering ? style.tone.color.opacity(0.24) : JournalTheme.border))
        .shadow(color: JournalTheme.accent.opacity(hovering ? 0.065 : 0.025), radius: hovering ? 10 : 5, y: 3)
        .offset(y: hovering && !reduceMotion ? -2 : 0).onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .sheet(item: $imagePreview) { RecordImagePreview(image: $0) }
    }
}
struct FollowUpMenu: View {
    @ObservedObject var app: AppModel
    let entry: Entry
    private var tone: JournalTheme.Tone { entry.status == .done ? .mint : entry.status == .pending ? .peach : .neutral }
    var body: some View {
        Menu {
            ForEach(FollowUp.allCases, id: \.self) { value in
                Button { app.setFollowUp(id: entry.id, status: value) } label: {
                    if value == entry.status { Label(value.rawValue, systemImage: "checkmark") } else { Text(value.rawValue) }
                }
            }
        } label: {
            Label(entry.status.rawValue, systemImage: entry.status == .done ? "checkmark.circle" : "circle")
                .font(.system(size: 11)).foregroundStyle(tone.color).padding(.horizontal, 7).padding(.vertical, 5)
                .background(tone.surface, in: RoundedRectangle(cornerRadius: 9))
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("跟进状态：" + entry.status.rawValue)
    }
}
struct RecordDetailView: View {
    @ObservedObject var app: AppModel
    let entryID: UUID
    @Environment(\.dismiss) private var dismiss
    @ViewState private var editing: Entry?
    private var entry: Entry? { app.entries.first { $0.id == entryID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { PageHeading(title: "记录详情", subtitle: entry?.day ?? "记录已移入回收站"); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let entry {
                HStack {
                    JournalSymbol(name: JournalTheme.category(entry.category).symbol, tone: JournalTheme.category(entry.category).tone)
                    Text(entry.category).font(.callout); Spacer(); FollowUpMenu(app: app, entry: entry)
                }
                ScrollView { RecordContentView(entry: entry).padding(20) }.journalCard(padding: 0)
                HStack {
                    Text(entry.inReport ? "已计入日报" : "未计入日报").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button { editing = entry } label: { Label("编辑记录", systemImage: "pencil") }.buttonStyle(JournalPrimaryButtonStyle())
                }
            } else { ContentUnavailableView("记录已移除", systemImage: "tray") }
        }.padding(24).frame(width: 640, height: 560).background(JournalTheme.canvas)
            .buttonStyle(JournalSecondaryButtonStyle()).tint(JournalTheme.accent)
            .sheet(item: $editing) { EntryEditor(app: app, entry: $0) }
    }
}
struct RecordImagePreview: View {
    let image: ImageAttachment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text(image.name).lineLimit(1); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let native = NSImage(data: image.data) { Image(nsImage: native).resizable().scaledToFit() }
        }.padding(20).frame(width: 680, height: 500).background(JournalTheme.canvas)
    }
}
