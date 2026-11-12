import SwiftUI
import JournalCore
import AppKit

// Explicit property-wrapper alias avoids the SDK 27 State macro plugin requirement.
typealias ViewState<Value> = SwiftUI.State<Value>

struct CaptureView: View {
    @ObservedObject var app: AppModel
    var close: () -> Void = {}
    @ObservedObject private var reminders: ReminderCoordinator
    init(app: AppModel, close: @escaping () -> Void = {}) { self.app = app; self.close = close; self.reminders = app.reminders }
    @ViewState private var showingCaptureCalendar = false
    @ViewState private var showingSchedule = false
    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                JournalSymbol(name: "square.and.pencil", tone: .violet, size: 44)
                PageHeading(title: "记下这一刻", subtitle: "进展、问题，或一个刚冒出来的想法。")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("随手记录", systemImage: "pencil.line").font(.system(size: 12, weight: .semibold)).foregroundStyle(JournalTheme.accent)
                    Spacer()
                    Label("本机保存", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }
                InlineRecordEditor(text: app.draft, images: app.draftImages,
                    changed: { app.replaceDraftContent($0, images: $1) }, onError: { app.error = $0 }).frame(height: 220)
                HStack(spacing: 14) {
                    Label("工作进展", systemImage: "checkmark.circle")
                    Label("问题排查", systemImage: "wrench.and.screwdriver")
                    Label("灵感想法", systemImage: "lightbulb")
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            }.journalCard(padding: 18)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "calendar").foregroundStyle(JournalTheme.accent).accessibilityHidden(true)
                    Text("归属日期").font(.callout)
                    Button(Days.key(app.draftDate)) { showingCaptureCalendar.toggle() }
                        .popover(isPresented: $showingCaptureCalendar) {
                            DatePicker("选择归属日期", selection: Binding(get: { app.draftDate }, set: { app.selectDraftDate($0); showingCaptureCalendar = false }), displayedComponents: .date)
                                .datePickerStyle(.graphical).padding(16)
                        }
                    Stepper("按天调整归属日期", onIncrement: { shiftCaptureDay(1) }, onDecrement: { shiftCaptureDay(-1) })
                        .labelsHidden().help("向上：后一天；向下：前一天")
                    Button("今天") { app.useTodayForDraft() }
                    Spacer()
                    Toggle(isOn: $app.draftInReport) { Label("计入日报", systemImage: "doc.text") }
                }
                Divider().overlay(JournalTheme.accent.opacity(0.08))
                HStack {
                    Image(systemName: "flag").foregroundStyle(JournalTheme.accent).accessibilityHidden(true)
                    Text("跟进").font(.callout)
                    ForEach(FollowUp.allCases, id: \.self) { value in
                        Button { app.draftStatus = value } label: {
                            Text(value.rawValue).font(.system(size: 12, weight: app.draftStatus == value ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(app.draftStatus == value ? Color.white : Color.primary)
                                .background(app.draftStatus == value ? JournalTheme.accentFill : JournalTheme.paper, in: RoundedRectangle(cornerRadius: 11))
                        }.buttonStyle(.plain).accessibilityLabel("跟进：" + value.rawValue)
                            .accessibilityValue(app.draftStatus == value ? "已选中" : "未选中")
                    }
                    Spacer()
                    Text("日报默认不勾选").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("截止时间与提醒", isExpanded: $showingSchedule) {
                    DueControls(optionalDate: $app.draftDueAt, reminderEnabled: $app.draftReminderEnabled, followUp: $app.draftStatus, recurrence: $app.draftRecurrence, status: reminders.status).padding(.top, 10)
                }
            }.journalCard(padding: 16)
        }.padding(24)
        }
            Divider().overlay(JournalTheme.border)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label(app.draftDateManual ? "手动补记" : "自动记录日期", systemImage: app.draftDateManual ? "calendar.badge.clock" : "clock")
                    Text("⌘ Return 保存").font(.system(size: 10, design: .monospaced))
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { if app.saveDraft() { close() } } label: { Label("保存记录", systemImage: "checkmark") }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(JournalPrimaryButtonStyle())
                    .disabled(app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && app.draftImages.isEmpty)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            if let error = app.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 12) }
        }.frame(minWidth: 580, minHeight: 520).background(JournalPageBackground())
            .buttonStyle(JournalSecondaryButtonStyle()).tint(JournalTheme.accent)
            .onAppear { showingSchedule = app.draftDueAt != nil }
    }
    private func shiftCaptureDay(_ amount: Int) {
        if let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: amount, to: app.draftDate) {
            app.selectDraftDate(next)
        }
    }
}

struct MainView: View {
    @ObservedObject var app: AppModel
    @ViewState private var section = "记录"
    @AppStorage("main.sidebarHidden") private var sidebarHidden = false
    var capture: () -> Void
    private let sections = [["记录", "待办"], ["日报", "周报"], ["笔记本"], ["回收站", "设置"]]
    private func symbol(_ item: String) -> String {
        ["笔记本": "books.vertical", "记录": "note.text", "待办": "checkmark.circle", "日报": "calendar", "周报": "book", "回收站": "archivebox", "设置": "slider.horizontal.3"][item] ?? "circle"
    }
    private func tone(_ item: String) -> JournalTheme.Tone {
        switch item { case "待办": return .mint; case "日报": return .blue; case "周报": return .peach; case "回收站", "设置": return .neutral; default: return .violet }
    }
    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().interpolation(.high)
                        .frame(width: 44, height: 44).accessibilityHidden(true)
                    Text("工作随记").font(.system(size: 16, weight: .semibold, design: .rounded))
                }.padding(.horizontal, 6).padding(.top, 12)
                VStack(spacing: 12) {
                    ForEach(sections, id: \.self) { group in
                        VStack(spacing: 5) {
                            ForEach(group, id: \.self) { item in
                                Button { navigate(item) } label: {
                                    HStack(spacing: 10) {
                                        JournalSymbol(name: symbol(item), tone: tone(item))
                                        Text(item).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                                        Spacer(minLength: 0)
                                        if item == "记录" { Text(app.entries.count.formatted()).font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.horizontal, 9).padding(.vertical, 8)
                                        .foregroundStyle(section == item ? JournalTheme.accent : JournalTheme.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(section == item ? JournalTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityValue(section == item ? "已选中" : "未选中")
                            }
                        }
                        if group != sections.last { Divider().overlay(JournalTheme.border).padding(.horizontal, 12) }
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Label("仅保存在这台 Mac", systemImage: "internaldrive")
                    Text(app.powerSaving ? "省电模式 · 暂缓后台整理" : "本地处理 · 安心记录")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 10)
            }.padding(.horizontal, 12).background(JournalTheme.sidebar)
                .frame(width: 190)
            Divider().overlay(JournalTheme.border)
            }
            VStack(spacing: 0) {
                HStack {
                    Button { sidebarHidden.toggle() } label: { Label(sidebarHidden ? "展开导航" : "收起导航", systemImage: "sidebar.left") }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 20).padding(.vertical, 8)
                Divider().overlay(JournalTheme.border)
                Group {
                    if section == "记录" { RecordsPageView(app: app, capture: capture, openSettings: { section = "设置" }) }
                    else if section == "日报" { ReportView(app: app) }
                    else if section == "待办" { TaskListView(app: app) }
                    else if section == "周报" { RangeSummaryView(app: app) }
                    else if section == "笔记本" { NotebookView(model: app.notebook, backup: app.exportBackup, restoreBackup: app.importBackup) }
                    else if section == "回收站" { TrashView(app: app) }
                    else { SettingsView(app: app) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(JournalTheme.border)
                HStack {
                    if app.busy { ProgressView().controlSize(.small); Text(app.generationProgress.isEmpty ? "本地模型处理中…" : app.generationProgress); Button("取消", action: app.cancel) }
                    else { Text(app.notice).lineLimit(2) }
                    Spacer(minLength: 10)
                    Text("\(app.entries.count) 条记录")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 9)
            }.background(JournalPageBackground())
        }
        .tint(JournalTheme.accent).buttonStyle(JournalSecondaryButtonStyle())
        .frame(minWidth: 900, minHeight: 640)
        .onChange(of: app.navigationTarget) { _, value in if let value { navigate(value); app.navigationTarget = nil } }
        .alert("操作未完成", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) { Button("知道了") { app.error = nil } } message: { Text(app.error ?? "") }
    }
    private func navigate(_ target: String) {
        guard target != section else { return }
        if section == "笔记本" {
            Task { do { try await app.notebook.leave(); section = target } catch { app.error = error.localizedDescription } }
        } else { section = target }
    }
}

struct EntryEditor: View {
    @ObservedObject var app: AppModel
    @ViewState var entry: Entry
    private let original: Entry
    @ObservedObject private var reminders: ReminderCoordinator
    @Environment(\.dismiss) private var dismiss
    @ViewState private var confirmDiscard = false
    init(app: AppModel, entry: Entry) {
        self.app = app; self.reminders = app.reminders; self.original = entry; self._entry = ViewState(wrappedValue: entry)
    }
    private var dirty: Bool { entry != original }
    var body: some View {
        VStack(spacing: 0) {
            HStack { JournalSymbol(name: "pencil", tone: .violet, size: 40); PageHeading(title: "编辑记录", subtitle: "修改后保存，记录才会更新。"); Spacer() }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InlineRecordEditor(text: entry.text, images: entry.images, changed: { entry.text = $0; entry.images = $1 }, onError: { app.error = $0 }).frame(height: 230).journalCard(padding: 16)
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("归属日期") { TextField("yyyy-MM-dd", text: $entry.day).frame(width: 160) }
                        LabeledContent("主要分类") { TextField("分类", text: $entry.category).frame(width: 160) }
                        Text("改为“未分类”可重新自动整理；只改正文或状态不会固定分类。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle("计入日报", isOn: $entry.inReport)
                        Picker("跟进状态", selection: $entry.status) { ForEach(FollowUp.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Divider()
                        DueControls(optionalDate: $entry.dueAt, reminderEnabled: $entry.reminderEnabled, followUp: $entry.status, recurrence: $entry.recurrence, status: reminders.status)
                        if let snoozed = entry.snoozedUntil, entry.status == .pending && entry.reminderEnabled {
                            Label("已延后至 " + snoozed.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.badge").font(.caption).foregroundStyle(.secondary)
                            Button("取消稍后提醒") { entry.snoozedUntil = nil }
                        }
                    }.journalCard(padding: 18).textFieldStyle(.roundedBorder)
                }.padding(.horizontal, 24).padding(.bottom, 18)
            }
            Divider()
            HStack {
                Button("取消") { if dirty { confirmDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存修改") { if app.saveEdited(original: original, edited: entry) { dismiss() } }
                    .buttonStyle(JournalPrimaryButtonStyle()).keyboardShortcut(.return, modifiers: .command)
            }.padding(20)
            if let error = app.error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal, 24).padding(.bottom, 12) }
        }.frame(width: 620, height: 610).background(JournalTheme.canvas)
            .buttonStyle(JournalSecondaryButtonStyle()).tint(JournalTheme.accent)
            .interactiveDismissDisabled(dirty)
            .confirmationDialog("放弃尚未保存的修改？", isPresented: $confirmDiscard) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
    }
}

struct ReportView: View {
    @ObservedObject var app: AppModel
    @ViewState private var date = Date()
    @ViewState private var text = ""
    @ViewState private var candidate: Report?
    @ViewState private var baselineFingerprint: String?
    @ViewState private var savedFingerprint: String?
    @ViewState private var versions: [Report] = []
    @ViewState private var loadedDay = Days.key(Date())
    @ViewState private var savedText = ""
    @ViewState private var showingArchive = false
    @ViewState private var showingExport = false
    @ViewState private var editingMarkdown = false
    @ViewState private var showingDatePicker = false
    @ViewState private var archiveSelection: String?
    @ViewState private var confirmDayChange = false
    @ViewState private var revertingDate = false
    private var day: String { Days.key(date) }
    private var currentFingerprint: String { ReportFreshness.fingerprint(day: loadedDay, entries: app.entries) }
    private var hasChanges: Bool { text != savedText || baselineFingerprint != savedFingerprint }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageHeading(title: "日报", subtitle: "把零散的进展，整理成清晰的一天。"); Spacer()
                HStack(spacing: 8) {
                    Button { showingDatePicker.toggle() } label: { Label(day, systemImage: "calendar") }
                        .popover(isPresented: $showingDatePicker) {
                            DatePicker("选择日期", selection: $date, displayedComponents: .date)
                                .datePickerStyle(.graphical).padding(16)
                        }
                    Stepper("按天调整日期", onIncrement: { shiftDay(1) }, onDecrement: { shiftDay(-1) })
                        .labelsHidden().help("向上：后一天；向下：前一天")
                }.disabled(app.busy)
            }
            HStack {
                Button("归档回顾") { showingArchive = true }.disabled(app.busy)
                Button { showingExport = true } label: { Label("导出日报", systemImage: "square.and.arrow.up") }
                Button("今天") { date = Date() }.disabled(app.busy || loadedDay == Days.key(Date()))
                Button("昨天") { date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date() }.disabled(app.busy)
                Spacer()
            }
            Text("选中日期的日报素材将整理到下方，生成后可继续编辑。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Label("\(app.entries.filter { $0.day == loadedDay && $0.inReport }.count) 条日报素材", systemImage: "doc.on.doc").font(.callout).foregroundStyle(JournalTheme.accent)
                Spacer()
                Button(app.reportQueued ? "日报已排队" : "生成日报") { app.generate(day: loadedDay) { candidate = $0 } }.buttonStyle(JournalPrimaryButtonStyle()).disabled((app.busy && !app.isClassifying) || app.checkingModels || app.reportQueued || app.model.isEmpty)
                Menu("历史版本（\(versions.count)）") {
                    ForEach(versions) { version in
                        Button(version.createdAt.formatted(date: .abbreviated, time: .standard)) { candidate = version }
                    }
                }.fixedSize().disabled(versions.isEmpty)
            }
            if !text.isEmpty && baselineFingerprint != currentFingerprint {
                HStack {
                    Label(baselineFingerprint == nil ? "此版本尚未记录素材基准，请核对内容" : "日报素材已变化，请核对或重新生成", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                    Spacer()
                    Button("已核对当前素材") { baselineFingerprint = currentFingerprint; persistDraft() }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("日报草稿", systemImage: "doc.text").font(.system(size: 12, weight: .medium))
                    Text(hasChanges && !text.isEmpty ? "有未保存修改" : !versions.isEmpty ? "已保存 · \(versions.count) 个版本" : text.isEmpty ? "尚未写日报" : "未保存草稿")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("显示模式", selection: $editingMarkdown) {
                        Text("预览").tag(false)
                        Text("编辑").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
                }
                Divider().opacity(0.5)
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("\(loadedDay) 尚未写日报\n可以直接书写，也可以从已勾选的素材生成日报。")
                            .font(.system(size: 14)).foregroundStyle(.tertiary).lineSpacing(7).padding(.top, 7).padding(.leading, 5).allowsHitTesting(false)
                    }
                    if editingMarkdown {
                        TextEditor(text: Binding(get: { text }, set: { text = $0; persistDraft() })).font(.system(size: 14)).lineSpacing(7).scrollContentBackground(.hidden)
                            .accessibilityLabel("编辑 Markdown 日报")
                    } else if !text.isEmpty {
                        MarkdownPreview(source: text)
                    } else {
                        VStack { Spacer(); Button("开始书写") { editingMarkdown = true }.buttonStyle(JournalPrimaryButtonStyle()); Spacer() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minHeight: 0, maxHeight: .infinity)
            }.journalCard(padding: 24)
            HStack {
                Text("编辑中的日期：\(loadedDay)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }.disabled(text.isEmpty)
                Button("保存新版本") { save() }.buttonStyle(JournalPrimaryButtonStyle()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(maxWidth: 1050).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingArchive, onDismiss: {
            guard let selected = archiveSelection else { return }
            archiveSelection = nil
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            if let selectedDate = formatter.date(from: selected), selected != loadedDay { date = selectedDate }
        }) {
            ReportArchiveView(app: app) { archiveSelection = $0 }
        }
        .sheet(isPresented: $showingExport) { ReportExportView(app: app, initialDate: date) }
        .onAppear { load(day) }
        .onChange(of: date) { _, _ in
            showingDatePicker = false
            if revertingDate { revertingDate = false; return }
            guard day != loadedDay else { return }
            if hasChanges { confirmDayChange = true } else { load(day) }
        }
        .confirmationDialog("当前日报有未保存修改", isPresented: $confirmDayChange) {
            Button("保存后切换") { if save() { load(day) } }
            Button("放弃修改并切换", role: .destructive) { clearDraft(); load(day) }
            Button("取消", role: .cancel) { restoreDate() }
        }
        .sheet(isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("候选版本预览").font(.title2.bold())
                Text("采用后会替换编辑区内容；当前内容若有修改，将先保存为历史版本。").foregroundStyle(.secondary)
                MarkdownPreview(source: candidate?.text ?? "").journalCard(padding: 18)
                HStack { Button("保留当前内容") { candidate = nil }; Spacer(); Button("采用候选版本") {
                    if hasChanges && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !save() { return }
                    if let candidate { text = candidate.text; baselineFingerprint = candidate.sourceFingerprint }; candidate = nil; persistDraft()
                }.buttonStyle(JournalPrimaryButtonStyle()) }
            }.padding(24).frame(width: 650, height: 500).background(JournalTheme.canvas).buttonStyle(JournalSecondaryButtonStyle())
        }
        .onDisappear { if hasChanges && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { save() } }
    }
    @discardableResult private func save() -> Bool {
        guard app.saveReport(day: loadedDay, text: text, sourceFingerprint: baselineFingerprint) else { return false }
        savedText = text; savedFingerprint = baselineFingerprint; clearDraft(); versions = app.versions(day: loadedDay); return true
    }
    private func persistDraft() {
        let draft = ReportDraft(text: text, sourceFingerprint: baselineFingerprint)
        if let data = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(data, forKey: "reportDraftV2." + loadedDay) }
    }
    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: "reportDraft." + loadedDay)
        UserDefaults.standard.removeObject(forKey: "reportDraftV2." + loadedDay)
    }
    private func load(_ day: String) {
        loadedDay = day; versions = app.versions(day: day)
        savedText = versions.first?.text ?? ""; savedFingerprint = versions.first?.sourceFingerprint
        var cached: ReportDraft?
        if let data = UserDefaults.standard.data(forKey: "reportDraftV2." + day) {
            cached = try? JSONDecoder().decode(ReportDraft.self, from: data)
        }
        if cached == nil, let legacy = UserDefaults.standard.string(forKey: "reportDraft." + day) {
            cached = ReportDraft(text: legacy, sourceFingerprint: nil)
        }
        let content = ReportDisplay.content(saved: versions.first, draft: cached)
        text = content.text; baselineFingerprint = content.sourceFingerprint
    }
    private func shiftDay(_ amount: Int) {
        if let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: amount, to: date) { date = next }
    }

    private func restoreDate() { revertingDate = true; let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; date = f.date(from: loadedDay) ?? date }
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PageHeading(title: "设置", subtitle: "让工作随记，适合你的工作节奏。").padding(.horizontal, 28).padding(.top, 28)
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "日报模板", symbol: "doc.text", tone: .violet) {
                Text("日期 → 开头固定内容 → 日报正文 → 结尾固定内容")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("开头固定内容").font(.callout)
                    TextEditor(text: $app.reportOpening)
                        .font(.body).scrollContentBackground(.hidden).frame(height: 90).padding(10)
                        .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(JournalTheme.border))
                        .accessibilityLabel("日报模板开头")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("结尾固定内容").font(.callout)
                    TextEditor(text: $app.reportClosing)
                        .font(.body).scrollContentBackground(.hidden).frame(height: 90).padding(10)
                        .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(JournalTheme.border))
                        .accessibilityLabel("日报模板结尾")
                }
                Text("默认留空，支持多行和 Markdown。输入后自动保存在本机，下次生成时原样添加，不交给模型改写；复制和导出会保留。修改模板不会改变已有日报，清空即可停用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection(title: "本地 AI", symbol: "sparkles", tone: .blue) {
                Text(app.serviceStatus).textSelection(.enabled)
                Text("1. 安装并打开 Ollama。2. 在 Ollama 下载支持文本生成的本地模型（不要选 cloud）。3. 刷新模型并试运行。")
                    .font(.callout)
                HStack {
                    Link("Ollama 官方下载", destination: URL(string: "https://ollama.com/download/mac")!)
                    Link("安装说明", destination: URL(string: "https://docs.ollama.com/macos")!)
                }
                Text("服务地址：127.0.0.1:11434。首次下载模型需联网；运行时记录不上传，不自动下载任何模型。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("已安装本地模型", selection: $app.model) {
                    Text("请选择本地模型").tag("")
                    if !app.model.isEmpty && !app.models.contains(app.model) { Text(app.model).tag(app.model) }
                    ForEach(app.models, id: \.self) { Text($0).tag($0) }
                }.disabled(app.busy || app.checkingModels)
                HStack {
                    Button(app.checkingModels ? "检查中…" : "检查连接并刷新模型") { Task { await app.refreshModels() } }.disabled(app.busy || app.checkingModels)
                    Button("试运行（内置示例）", action: app.runModelTrial).disabled(app.busy || app.checkingModels || !app.models.contains(app.model))
                }
                Text("试运行只使用内置示例，测试分类与日报生成，不读取或保存你的工作内容。结果包含耗时和模型原文，需自行核对质量。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection(title: "资源使用", symbol: "leaf", tone: .mint) {
                Picker("后台处理模式", selection: $app.powerMode) {
                    ForEach(PowerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text(app.powerState.source.rawValue + (app.powerState.lowPower ? " · 系统低电量模式" : "") + (app.powerState.hot ? " · 温度较高" : ""))
                Text(app.powerSaving ? "当前：暂缓后台分类" : "当前：允许后台分类").foregroundStyle(.secondary)
                Text("自动模式在电池供电、系统低电量、温度较高或电源状态未知时暂缓后台分类。外接电源且状态正常时自动接续，短时间内的输入会合并排队。手动整理不受限制。手动日报优先于后续分类。失败或取消后暂停自动处理，可点击“整理未分类”重试。模型请求完成后保留 60 秒再释放。") .font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection(title: "快捷记录", symbol: "keyboard", tone: .violet) { ShortcutSettings(app: app) }
            SettingsSection(title: "分类管理", symbol: "square.grid.2x2", tone: .peach) { CategoryManager(app: app) }
            SettingsSection(title: "待办提醒", symbol: "bell", tone: .blue) { ReminderSettingsView(coordinator: app.reminders) }
            SettingsSection(title: "数据", symbol: "internaldrive", tone: .neutral) { Button("导出完整 JSON 备份", action: app.exportBackup); Button("从备份合并恢复", action: app.importBackup).disabled(app.busy); Text("数据保存在 Application Support/WorkJournal。备份包含记录、回收站、日报、周报、笔记与附件，请妥善保管。").font(.caption).foregroundStyle(.secondary) }
        }.padding(26)
        }
        }.frame(maxWidth: 960).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .sheet(item: $app.modelTrial) { result in ModelTrialView(result: result) }
    }
}


struct CategoryManager: View {
    @ObservedObject var app: AppModel
    @ViewState private var source = ""
    @ViewState private var target = ""
    @ViewState private var confirming = false
    private var available: [String] { app.categories.filter { $0 != "未分类" } }
    var body: some View {
        Picker("原分类", selection: $source) {
            Text("选择分类").tag("")
            ForEach(available, id: \.self) { Text($0).tag($0) }
        }
        TextField("新的分类名称", text: $target)
        Text("填入已有分类名称即可合并。只调整记录的主要分类，已保存的日报内容保持不变。").font(.caption).foregroundStyle(.secondary)
        Button("改名 / 合并分类") { confirming = true }
            .disabled(source.isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.busy)
            .confirmationDialog("将“\(source)”中的记录归入“\(target)”？", isPresented: $confirming) {
                Button("确认改名 / 合并") {
                    if app.renameCategory(from: source, to: target) { source = ""; target = "" }
                }
                Button("取消", role: .cancel) {}
            }
    }
}


struct ShortcutSettings: View {
    @ObservedObject var app: AppModel
    @ViewState private var proposed = ShortcutConfiguration()
    var body: some View {
        Text(app.shortcutStatus)
        HStack {
            Toggle("Control", isOn: $proposed.control)
            Toggle("Option", isOn: $proposed.option)
            Toggle("Command", isOn: $proposed.command)
            Toggle("Shift", isOn: $proposed.shift)
        }.toggleStyle(.checkbox)
        Picker("按键", selection: $proposed.keyCode) {
            ForEach(ShortcutConfiguration.keys, id: \.code) { key in Text(key.label).tag(key.code) }
        }
        HStack {
            Button("应用快捷键") { app.applyShortcut(proposed) }
            Button("恢复默认") { app.applyShortcut(ShortcutConfiguration()); proposed = app.shortcut }
        }
        Text("至少组合 Control、Option、Command 中的两个。按键按键盘物理位置识别。注册失败时保留旧快捷键，仍可从菜单栏记一笔。").font(.caption).foregroundStyle(.secondary)
            .onAppear { proposed = app.shortcut }
    }
}


struct ModelTrialView: View {
    let result: ModelTrialResult
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地模型试运行结果").font(.title2.bold())
            Text("模型：\(result.model) · 总耗时：\(result.elapsedSeconds, specifier: "%.1f") 秒")
            Text("耗时包含模型加载，不代表稳定速度或耗电评估。本次没有写入任何记录或日报。")
                .font(.caption).foregroundStyle(.secondary)
            Text("示例分类：" + result.category)
            Text("核对要点：Review 已完成；超时原因未确认、尚未修复；缓存阅读只是计划。")
                .foregroundStyle(.secondary)
            ScrollView { Text(result.report).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer(); Button("完成") { dismiss() }.buttonStyle(JournalPrimaryButtonStyle()) }
        }.padding(24).frame(width: 660, height: 510)
    }
}
