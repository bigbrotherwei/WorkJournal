import Foundation
import Testing
@testable import JournalCore

struct ReminderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func reminder() -> Entry {
        var value = Entry(text: "提交方案", day: "2026-01-01")
        value.status = .pending; value.dueAt = now.addingTimeInterval(60); value.reminderEnabled = true
        return value
    }
    @Test func onlyFutureActiveRemindersSchedule() {
        var entry = reminder()
        #expect(ReminderPolicy.shouldSchedule(entry, now: now))
        entry.dueAt = now
        #expect(!ReminderPolicy.shouldSchedule(entry, now: now))
        entry.dueAt = now.addingTimeInterval(-60)
        #expect(!ReminderPolicy.shouldSchedule(entry, now: now))
        #expect(ReminderPolicy.isActive(entry))
        entry.status = .done
        #expect(!ReminderPolicy.isActive(entry))
        entry.status = .pending; entry.deletedAt = now
        #expect(!ReminderPolicy.isActive(entry))
        entry.deletedAt = nil; entry.reminderEnabled = false
        #expect(!ReminderPolicy.isActive(entry))
        entry.reminderEnabled = true; entry.dueAt = nil
        #expect(!ReminderPolicy.isActive(entry))
    }
    @Test func taskGroupsRespectLocalDayAndActualDeadline() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let current = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 23, minute: 30))!
        var entry = reminder()
        entry.dueAt = current.addingTimeInterval(-60)
        #expect(ReminderPolicy.group(for: entry, now: current, calendar: calendar) == .overdue)
        entry.dueAt = current.addingTimeInterval(60)
        #expect(ReminderPolicy.group(for: entry, now: current, calendar: calendar) == .today)
        entry.dueAt = current.addingTimeInterval(3600)
        #expect(ReminderPolicy.group(for: entry, now: current, calendar: calendar) == .future)
        entry.dueAt = nil
        #expect(ReminderPolicy.group(for: entry, now: current, calendar: calendar) == .noDate)
    }
    @Test func pendingRequestMatchingPreservesDeadlineCrossingAndRejectsChanges() {
        var entry = reminder()
        let timestamp = entry.dueAt!.timeIntervalSince1970
        let body = ReminderPolicy.notificationBody(for: entry)
        // Matching intentionally has no `now` parameter: an unchanged queued request
        // must survive reconciliation even if its deadline crosses during an await.
        #expect(ReminderPolicy.matchesPending(entry, dueTimestamp: timestamp, body: body))
        #expect(!ReminderPolicy.shouldSchedule(entry, now: entry.dueAt!.addingTimeInterval(1)))
        #expect(ReminderPolicy.matchesPending(entry, dueTimestamp: timestamp, body: body))
        entry.dueAt = entry.dueAt!.addingTimeInterval(60)
        #expect(!ReminderPolicy.matchesPending(entry, dueTimestamp: timestamp, body: body))
        entry.dueAt = Date(timeIntervalSince1970: timestamp); entry.text = "修改内容"
        #expect(!ReminderPolicy.matchesPending(entry, dueTimestamp: timestamp, body: body))
        entry.text = body; entry.status = .done
        #expect(!ReminderPolicy.matchesPending(entry, dueTimestamp: timestamp, body: body))
        entry.status = .pending; entry.deletedAt = now
        #expect(!ReminderPolicy.matchesPending(entry, dueTimestamp: timestamp, body: body))
    }
    @Test func pendingExcludesTrashAndSortsUndatedLast() {
        var later = reminder(); later.dueAt = now.addingTimeInterval(600)
        let earlier = reminder()
        var undated = reminder(); undated.dueAt = nil
        var deleted = reminder(); deleted.deletedAt = now
        var done = reminder(); done.status = .done
        #expect(ReminderPolicy.pending(in: [undated, later, deleted, done, earlier]).map(\.id) == [earlier.id, later.id, undated.id])
        #expect(ReminderPolicy.identifier(for: earlier.id) == ReminderPolicy.identifierPrefix + earlier.id.uuidString)
    }
}
