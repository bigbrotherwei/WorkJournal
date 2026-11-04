import Foundation
import Testing
@testable import JournalCore

struct RecordActivityTests {
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    func date(_ text: String) -> Date {
        let f = ISO8601DateFormatter(); return f.date(from: text)!
    }
    @Test func twelveWeeksAlignMondayAndExcludeFutureAndOldRecords() {
        let now = date("2026-11-04T12:00:00+08:00")
        let entries = ["2026-11-03", "2026-11-03", "2026-11-04", "2026-11-05", "2025-01-01"].map { Entry(text: "记录", day: $0) }
        let activity = RecordActivity(entries: entries, now: now, timeZone: zone)
        #expect(activity.days.count == 84)
        #expect(activity.days.first?.day == "2026-08-17")
        #expect(activity.days.last?.day == "2026-11-08")
        #expect(activity.total == 3)
        #expect(activity.activeDays == 2)
        #expect(activity.days.first { $0.day == "2026-11-03" }?.count == 2)
        #expect(activity.days.last?.isFuture == true)
        #expect(activity.days.first { $0.day == "2026-11-05" }?.count == 0)
    }
    @Test func assignedDateCountsAllRecordsRegardlessOfReportFlag() {
        var first = Entry(text: "普通记录", day: "2026-11-03"); first.inReport = false
        var second = first; second.id = UUID(); second.inReport = true
        let activity = RecordActivity(entries: [first, second], now: date("2026-11-04T12:00:00+08:00"), timeZone: zone)
        #expect(activity.total == 2)
        #expect(activity.activeDays == 1)
    }
    @Test func levelsAndEmptyYearBoundaryAreStable() {
        #expect([0, 1, 2, 3, 4, 5, 6, 20].map(RecordActivity.level) == [0, 1, 2, 2, 3, 3, 4, 4])
        let empty = RecordActivity(entries: [], now: date("2027-01-03T12:00:00+08:00"), timeZone: zone)
        #expect(empty.days.last?.day == "2027-01-03")
        #expect(empty.days.allSatisfy { !$0.isFuture && $0.count == 0 })
        #expect(empty.total == 0 && empty.activeDays == 0)
    }
}
