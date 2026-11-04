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
    @ViewState private var editing: Entry?
    @ViewState private var snoozing: Entry?
    private var pending: [Entry] { ReminderPolicy.pending(in: app.entries) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: "待办", subtitle: "按截止时间查看需要跟进的事项。")
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if pending.isEmpty {
                    ContentUnavailableView("暂无待处理事项", systemImage: "checkmark.circle", description: Text("把记录标为“待处理”，即可在这里跟进。"))
                } else {
                    List {
                        ForEach(TaskDueGroup.allCases, id: \.self) { group in
                            let items = pending.filter { ReminderPolicy.group(for: $0, now: context.date) == group }
                            if !items.isEmpty {
                                Section(group.rawValue + " · \(items.count)") {
                                    ForEach(items) { entry in
                                        HStack(alignment: .top, spacing: 12) {
                                            Button { app.setFollowUp(id: entry.id, status: .done) } label: { Image(systemName: "circle").font(.title3) }
                                                .buttonStyle(.plain).help("标为已完成").accessibilityLabel("标为已完成")
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(entry.plainText.isEmpty ? "图片记录" : entry.plainText).lineLimit(3)
                                                HStack {
                                                    Text("记录日期 " + entry.day)
                                                    if let due = entry.dueAt { Text("截止 " + due.formatted(date: .abbreviated, time: .shortened)) }
                                                    if entry.reminderEnabled { Image(systemName: "bell") }
                                                    if entry.recurrence != .none { Label(entry.recurrence.label, systemImage: "repeat") }
                                                }.font(.caption).foregroundStyle(.secondary)
                                                if let snoozed = entry.snoozedUntil, entry.reminderEnabled {
                                                    Label("提醒 " + snoozed.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.badge")
                                                        .font(.caption).foregroundStyle(JournalTheme.accent)
                                                }
                                            }
                                            Spacer()
                                            if entry.dueAt != nil {
                                                Menu {
                                                    ForEach(SnoozeChoice.allCases, id: \.self) { choice in
                                                        Button(choice.label) { app.snooze(entry.id, until: choice.date()) }
                                                    }
                                                    Button("自选时间…") { snoozing = entry }
                                                } label: { Label("稍后提醒", systemImage: "clock.arrow.circlepath") }
                                                .fixedSize()
                                            }
                                            Button("编辑") { editing = entry }
                                        }.padding(.vertical, 7).accessibilityElement(children: .contain)
                                    }
                                }
                            }
                        }
                    }.listStyle(.inset)
                }
            }
        }.padding(28)
        .sheet(item: $editing) { EntryEditor(app: app, entry: $0) }
        .sheet(item: $snoozing) { SnoozeTimeView(app: app, entry: $0) }
    }
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
