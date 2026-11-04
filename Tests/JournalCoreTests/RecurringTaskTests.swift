import Foundation
import Testing
@testable import JournalCore

struct RecurringTaskTests {
    @Test func legacyPayloadDefaultsToNoRecurrenceOrSnooze() throws {
        let entry = Entry(text: "旧版演示记录", day: "2026-11-04")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for key in ["recurrence", "recurrenceClock", "recurrenceDayOfMonth", "recurrenceSeriesID", "nextOccurrenceID", "snoozedUntil"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.recurrence == .none && decoded.snoozedUntil == nil)
        #expect(decoded.recurrenceClock == nil && decoded.recurrenceSeriesID == nil && decoded.nextOccurrenceID == nil)
    }
    @Test func snoozePayloadDelaysReminderWithoutMovingDeadline() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var entry = Entry(text: "演示待办", day: "2026-11-04")
        entry.status = .pending; entry.reminderEnabled = true
        entry.dueAt = now.addingTimeInterval(-60)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["snoozedUntil"] = now.addingTimeInterval(1800).timeIntervalSinceReferenceDate
        object["recurrence"] = "daily"
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(ReminderPolicy.shouldSchedule(decoded, now: now))
        #expect(decoded.dueAt == entry.dueAt)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(encoded["recurrence"] as? String == "daily")
        #expect(encoded["snoozedUntil"] as? Double == now.addingTimeInterval(1800).timeIntervalSinceReferenceDate)
    }
}

struct RecurringStorageTests {
    private func setup() throws -> (URL, JournalStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recurring-\(UUID())")
        return (root, try JournalStore(url: root.appendingPathComponent("journal.sqlite")))
    }
    private func task(_ recurrence: TaskRecurrence, due: Date) -> Entry {
        var entry = Entry(text: "复核演示模块", day: Days.key(due))
        entry.status = .pending; entry.dueAt = due; entry.reminderEnabled = true
        entry.recurrence = recurrence; entry.inReport = true
        return entry
    }
    @Test func completionCreatesExactlyOneNextOccurrenceAndKeepsHistory() throws {
        let (root, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let due = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        var entry = task(.weekly, due: due); try store.save(entry)
        entry.status = .done; try store.save(entry)
        let entries = try store.entries()
        #expect(entries.count == 2)
        let next = try #require(entries.first { $0.id != entry.id })
        #expect(next.status == .pending && next.recurrence == .weekly)
        #expect(next.dueAt == Calendar.current.date(byAdding: .day, value: 7, to: due))
        #expect(!next.inReport && next.snoozedUntil == nil)
        let previous = try #require(entries.first { $0.id == entry.id })
        #expect(previous.status == .done && previous.nextOccurrenceID == next.id)
        #expect(previous.recurrenceSeriesID == entry.id && next.recurrenceSeriesID == entry.id)
        try store.save(entry) // A repeated/stale completion cannot produce another task.
        #expect(try store.entries().count == 2)
        entry.status = .pending
        #expect(throws: (any Error).self) { try store.save(entry) }
        #expect(try store.entries().count == 2)
    }
    @Test func disablingReminderOrChangingDeadlineClearsSnooze() throws {
        let (root, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        var entry = task(.none, due: Date().addingTimeInterval(3600))
        entry.snoozedUntil = Date().addingTimeInterval(7200); try store.save(entry)
        entry.reminderEnabled = false; try store.save(entry)
        #expect(try store.entries().first?.snoozedUntil == nil)
        entry.reminderEnabled = true; entry.snoozedUntil = Date().addingTimeInterval(7200)
        try store.save(entry)
        entry.dueAt = entry.dueAt!.addingTimeInterval(60); try store.save(entry)
        #expect(try store.entries().first?.snoozedUntil == nil)
    }
    @Test func malformedRecurrenceRejectedAndCompletionRollsBackOnBadContent() throws {
        let (root, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        var entry = task(.daily, due: Date().addingTimeInterval(3600)); entry.dueAt = nil
        #expect(throws: (any Error).self) { try store.save(entry) }
        entry.dueAt = Date().addingTimeInterval(3600); try store.save(entry)
        entry.status = .done; entry.text = ""
        #expect(throws: (any Error).self) { try store.save(entry) }
        #expect(try store.entries().count == 1)
        #expect(try store.entries().first?.status == .pending)
    }
    @Test func snoozeAndRecurrenceSurviveTrashRestoreAndBackupWithoutAdvancing() throws {
        let (root, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        var entry = task(.daily, due: Date().addingTimeInterval(3600))
        entry.snoozedUntil = Date().addingTimeInterval(7200)
        try store.save(entry); try store.delete(id: entry.id)
        let other = try JournalStore(url: root.appendingPathComponent("restored.sqlite"))
        _ = try other.importBackup(store.exportBackup()); try other.restore(id: entry.id)
        #expect(try other.entries().count == 1)
        #expect(try other.entries().first?.recurrence == .daily)
        #expect(try other.entries().first?.snoozedUntil == entry.snoozedUntil)
    }
    @Test func staleEditorPreservesSnoozeUnlessDeadlineOrReminderChanged() throws {
        var original = task(.daily, due: Date().addingTimeInterval(3600))
        var current = original; current.snoozedUntil = Date().addingTimeInterval(7200)
        var edited = original; edited.text = "修改文字"
        #expect(try EntryEditing.merge(original: original, edited: edited, current: current).snoozedUntil == current.snoozedUntil)
        original = current; edited = current; edited.recurrence = .weekly
        #expect(try EntryEditing.merge(original: original, edited: edited, current: current).recurrence == .weekly)
    }
}

struct RecurrenceCalendarTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func task(_ recurrence: TaskRecurrence, _ due: Date) -> Entry {
        var entry = Entry(text: "合成日历测试", day: "2026-01-01")
        entry.dueAt = due; entry.recurrence = recurrence; return entry
    }
    @Test func monthlyRetains31stAnchorAfterFebruaryAndLateCompletion() throws {
        var entry = task(.monthly, date(2026, 1, 31))
        #expect(try RecurringTasks.nextDeadline(for: entry, after: date(2026, 1, 31), calendar: calendar) == date(2026, 2, 28))
        entry.dueAt = date(2026, 2, 28); entry.recurrenceDayOfMonth = 31
        #expect(try RecurringTasks.nextDeadline(for: entry, after: date(2026, 3, 29), calendar: calendar) == date(2026, 3, 31))
    }
    @Test func weekdaysSkipWeekendAndDailyPreservesTimeAcrossDST() throws {
        let friday = task(.weekdays, date(2026, 3, 6))
        #expect(try RecurringTasks.nextDeadline(for: friday, after: date(2026, 3, 6), calendar: calendar) == date(2026, 3, 9))
        let daily = task(.daily, date(2026, 3, 7))
        #expect(try RecurringTasks.nextDeadline(for: daily, after: date(2026, 3, 7), calendar: calendar) == date(2026, 3, 8))
        let weekly = task(.weekly, date(2026, 3, 2))
        #expect(try RecurringTasks.nextDeadline(for: weekly, after: date(2026, 3, 25), calendar: calendar) == date(2026, 3, 30))
    }
    @Test func snoozeUsesTomorrowMorningAndRejectsPastCompletedDeletedTasks() throws {
        let now = date(2026, 3, 7, 23)
        #expect(SnoozeChoice.tomorrow.date(from: now, calendar: calendar) == date(2026, 3, 8))
        #expect(SnoozeChoice.halfHour.date(from: now) == now.addingTimeInterval(1800))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snooze-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("a.sqlite"))
        var entry = task(.none, now.addingTimeInterval(-60)); entry.status = .pending
        try store.save(entry)
        #expect(throws: (any Error).self) { try store.snooze(id: entry.id, until: now, now: now) }
        try store.snooze(id: entry.id, until: now.addingTimeInterval(1800), now: now)
        let snoozed = try #require(store.entries().first)
        #expect(snoozed.dueAt == entry.dueAt && snoozed.reminderEnabled)
        #expect(ReminderPolicy.shouldSchedule(snoozed, now: now))
        #expect(!ReminderPolicy.matchesPending(snoozed, dueTimestamp: entry.dueAt!.timeIntervalSince1970, body: entry.text))
        entry.status = .done; try store.save(entry)
        #expect(throws: (any Error).self) { try store.snooze(id: entry.id, until: now.addingTimeInterval(1800), now: now) }
        try store.delete(id: entry.id)
        #expect(throws: (any Error).self) { try store.snooze(id: entry.id, until: now.addingTimeInterval(1800), now: now) }
    }
}

struct RecurrenceRegressionTests {
    @Test func mergeBackupDoesNotCreateTwoActiveOccurrences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recurrence-merge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try JournalStore(url: root.appendingPathComponent("local.sqlite"))
        let source = try JournalStore(url: root.appendingPathComponent("source.sqlite"))
        var entry = Entry(text: "重复事项合并测试", day: "2026-11-04")
        entry.status = .pending; entry.recurrence = .daily; entry.dueAt = Date().addingTimeInterval(3600)
        try local.save(entry); try source.save(entry)
        entry.status = .done; try source.save(entry)
        let result = try local.importBackup(source.exportBackup())
        #expect(result.entries == 0 && result.skipped == 2)
        #expect(try local.entries().filter { $0.status == .pending }.count == 1)
        entry.status = .done; try local.save(entry)
        #expect(try local.entries().filter { $0.status == .pending }.count == 1)
    }
    @Test func weekdaysDoNotInheritSundayDSTNormalization() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func d(_ day: Int) -> Date { c.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 2, minute: 30))! }
        var entry = Entry(text: "时区边界", day: "2026-03-06")
        entry.dueAt = d(6); entry.recurrence = .weekdays
        #expect(try RecurringTasks.nextDeadline(for: entry, after: d(6), calendar: c) == d(9))
    }
}

struct RecurrenceFinalTests {
    @Test func dailyClockAnchorSurvivesDSTAdjustedOccurrence() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func d(_ day: Int, _ hour: Int = 2) -> Date { c.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: 30))! }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clock-anchor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("a.sqlite"))
        var entry = Entry(text: "每日时刻锚点", day: "2026-03-07")
        entry.status = .pending; entry.recurrence = .daily; entry.dueAt = d(7)
        try store.save(entry, now: d(7), calendar: c)
        entry.status = .done; try store.save(entry, now: d(7), calendar: c)
        var second = try #require(store.entries().first { $0.status == .pending })
        #expect(second.dueAt == d(8, 3))
        second.status = .done; try store.save(second, now: d(8, 3), calendar: c)
        #expect(try store.entries().first { $0.status == .pending }?.dueAt == d(9))
    }
    @Test func backupWithoutPermanentlyDeletedAncestorCannotForkLiveSeries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("partial-series-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try JournalStore(url: root.appendingPathComponent("local.sqlite"))
        let source = try JournalStore(url: root.appendingPathComponent("source.sqlite"))
        var entry = Entry(text: "保留本机活跃重复事项", day: "2026-11-04")
        entry.status = .pending; entry.recurrence = .daily; entry.dueAt = Date().addingTimeInterval(3600)
        try local.save(entry); try source.save(entry)
        entry.status = .done; try source.save(entry)
        try source.delete(id: entry.id); try source.permanentlyDelete(id: entry.id)
        let result = try local.importBackup(source.exportBackup())
        #expect(result.entries == 0 && result.skipped == 1)
        #expect(try local.entries().count == 1)
    }
}
