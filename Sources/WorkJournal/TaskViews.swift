import SwiftUI
import JournalCore

struct DueControls: View {
    @Binding var optionalDate: Date?
    @Binding var reminderEnabled: Bool
    @Binding var followUp: FollowUp
    @Binding var recurrence: TaskRecurrence
    var status: ReminderAuthorizationStatus
    @ViewState private var showingCalendar = false
    private var date: Binding<Date> {
        Binding(get: { optionalDate ?? Date().addingTimeInterval(3600) }, set: { optionalDate = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("设置截止时间", isOn: Binding(get: { optionalDate != nil }, set: { enabled in
                optionalDate = enabled ? Date().addingTimeInterval(3600) : nil
                if enabled { followUp = .pending } else { reminderEnabled = false; recurrence = .none }
            }))
            if optionalDate != nil {
                HStack(spacing: 8) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }.help("前一天")
                    Button { showingCalendar.toggle() } label: {
                        Label(date.wrappedValue.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    }.popover(isPresented: $showingCalendar) {
                        DatePicker("截止日期", selection: date, displayedComponents: .date)
                            .datePickerStyle(.graphical).padding(16)
                    }
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.help("后一天")
                    DatePicker("时间", selection: date, displayedComponents: .hourAndMinute).labelsHidden().frame(width: 105)
                }
                Picker("重复", selection: $recurrence) {
                    ForEach(TaskRecurrence.allCases, id: \.self) { Text($0.label).tag($0) }
                }.disabled(followUp != .pending)
                if recurrence != .none {
                    Text("完成后生成下一期，跳过已过期的周期；新一期默认不计入日报。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("到期时通知我", isOn: $reminderEnabled).disabled(followUp != .pending)
                if followUp != .pending {
                    Text("待处理事项可启用提醒").font(.caption).foregroundStyle(.secondary)
                } else if reminderEnabled {
                    Text(status.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let due = optionalDate, due <= Date() {
                        Text("截止时间已过，将在待办中显示逾期，不补发通知。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: followUp) { _, value in
            if value == .none { recurrence = .none; reminderEnabled = false }
        }
    }
    private func shift(_ days: Int) {
        date.wrappedValue = Calendar.current.date(byAdding: .day, value: days, to: date.wrappedValue) ?? date.wrappedValue
    }
}

struct TaskListView: View {
    @ObservedObject var app: AppModel
    @ViewState private var editAnchors = TaskEditAnchors()
    private var pending: [Entry] { ReminderPolicy.pending(in: app.entries) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    PageHeading(title: "待办", subtitle: "专注下一步，点开事项即可安排时间。")
                    Spacer()
                    Text("\(pending.count) 项待处理").font(.callout).foregroundStyle(JournalTheme.Tone.mint.color)
                        .padding(12).background(JournalTheme.Tone.mint.surface, in: Capsule())
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if pending.isEmpty {
                        ContentUnavailableView("暂无待处理事项", systemImage: "checkmark.circle", description: Text("把记录标为“待处理”，即可在这里跟进。"))
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(TaskDueGroup.allCases, id: \.self) { group in
                                let items = pending.filter { editAnchors.group(for: $0, now: context.date) == group }
                                if !items.isEmpty {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(group.rawValue + " · \(items.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                                        ForEach(items) { entry in
                                            TaskRowView(app: app, entry: entry) { active in
                                                if active { editAnchors.begin(entry, now: context.date) }
                                                else { editAnchors.end(entry.id) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }.padding(26).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
    }
}

private struct TaskRowView: View {
    @ObservedObject var app: AppModel
    let entry: Entry
    let editingChanged: (Bool) -> Void
    @ObservedObject private var reminders: ReminderCoordinator
    @ViewState private var original: Entry
    @ViewState private var draft: Entry
    @ViewState private var expanded = false
    @ViewState private var editing = false
    @ViewState private var snoozing = false
    @ViewState private var confirmDiscard = false
    init(app: AppModel, entry: Entry, editingChanged: @escaping (Bool) -> Void) {
        self.app = app; self.entry = entry; self.editingChanged = editingChanged; reminders = app.reminders
        _original = ViewState(wrappedValue: entry); _draft = ViewState(wrappedValue: entry)
    }
    private var dirty: Bool { expanded && draft != original }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Button { app.setFollowUp(id: entry.id, status: .done) } label: {
                    Image(systemName: "circle").font(.system(size: 22, weight: .light)).foregroundStyle(JournalTheme.Tone.mint.color)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(dirty).help(dirty ? "先保存或取消时间调整" : "标为已完成").accessibilityLabel("标为已完成")
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entry.plainText.isEmpty ? "图片记录" : entry.plainText).font(.system(size: 14, weight: .medium)).lineSpacing(4).lineLimit(expanded ? nil : 2).foregroundStyle(JournalTheme.ink)
                        HStack(spacing: 10) {
                            Text(entry.category)
                            if let due = entry.dueAt { Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: entry.reminderEnabled ? "bell" : "calendar") }
                            if entry.recurrence != .none { Label(entry.recurrence.label, systemImage: "repeat") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let snoozed = entry.snoozedUntil, entry.reminderEnabled {
                            Text("提醒延后至 " + snoozed.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(JournalTheme.accent)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("展开待办：" + entry.plainText).accessibilityValue(expanded ? "已展开" : "已折叠")
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary).padding(.top, 9).accessibilityHidden(true)
            }
            if expanded {
                Divider().overlay(JournalTheme.border)
                DueControls(optionalDate: $draft.dueAt, reminderEnabled: $draft.reminderEnabled, followUp: $draft.status, recurrence: $draft.recurrence, status: reminders.status)
                HStack(spacing: 10) {
                    Button("编辑内容") { editing = true }.disabled(dirty)
                    if entry.dueAt != nil {
                        Menu("稍后提醒") {
                            ForEach(SnoozeChoice.allCases, id: \.self) { choice in Button(choice.label) { app.snooze(entry.id, until: choice.date()) } }
                            Button("自选时间…") { snoozing = true }
                        }.fixedSize().disabled(dirty)
                    }
                    Spacer()
                    Button("取消", action: collapse)
                    Button("保存安排") {
                        if app.saveEdited(original: original, edited: draft) { collapse() }
                    }.buttonStyle(JournalPrimaryButtonStyle()).disabled(!dirty)
                }
                if dirty { Text("时间安排尚未保存；保存后可完成或编辑内容。").font(.caption).foregroundStyle(.secondary) }
            }
        }.journalCard(padding: 18)
            .sheet(isPresented: $editing, onDismiss: resetDraft) { EntryEditor(app: app, entry: entry) }
            .sheet(isPresented: $snoozing) { SnoozeTimeView(app: app, entry: entry) }
            .confirmationDialog("放弃尚未保存的时间安排？", isPresented: $confirmDiscard) {
                Button("放弃并收起", role: .destructive, action: collapse)
                Button("继续编辑", role: .cancel) {}
            }
    }
    private func resetDraft() { let latest = app.entries.first { $0.id == entry.id } ?? entry; original = latest; draft = latest }
    private func toggle() {
        if expanded { if dirty { confirmDiscard = true } else { collapse() } }
        else { resetDraft(); editingChanged(true); expanded = true }
    }
    private func collapse() { expanded = false; editingChanged(false) }
}

struct ReminderSettingsView: View {
    @ObservedObject var coordinator: ReminderCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("到期提醒").font(.headline)
            Text(coordinator.status.message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("允许通知 / 检查权限") { Task { await coordinator.requestAuthorization() } }
                Button(coordinator.sendingTest ? "正在安排…" : "发送测试通知") {
                    Task { await coordinator.sendTestNotification() }
                }.disabled(coordinator.sendingTest || coordinator.status != .authorized)
            }
            Text("启用提醒后，待处理事项会在截止时间通知，退出应用后仍有效。可在待办或通知中选择稍后提醒，原截止时间不变。重复待办完成后生成下一期；逾期事项不补发通知。")
                .font(.caption).foregroundStyle(.secondary)
            if let feedback = coordinator.testFeedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = coordinator.schedulingError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .task {
            await coordinator.refreshAuthorization()
            await coordinator.refreshTestDelivery()
        }
    }
}

struct SnoozeTimeView: View {
    @ObservedObject var app: AppModel
    let entry: Entry
    @ViewState private var date = Date().addingTimeInterval(3600)
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("稍后提醒").font(.title2.bold())
            Text(entry.plainText).lineLimit(2).foregroundStyle(.secondary)
            DatePicker("提醒日期", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
            DatePicker("提醒时间", selection: $date, displayedComponents: .hourAndMinute)
            Text("只调整提醒时间，原截止时间不变。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("安排提醒") { app.snooze(entry.id, until: date); dismiss() }
                    .disabled(date <= Date()).buttonStyle(JournalPrimaryButtonStyle())
            }
        }.padding(24).frame(width: 380)
    }
}
