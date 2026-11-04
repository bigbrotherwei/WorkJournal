import Foundation
import Testing
@testable import JournalCore

struct JournalCoreTests {
    func temporaryDB() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID()).sqlite") }
    @Test func persistenceAndUpdate() throws {
        let url = temporaryDB()
        defer { try? FileManager.default.removeItem(at: url) }
        var entry = Entry(text: "排查登录超时", day: "2026-10-29")
        let store = try JournalStore(url: url)
        try store.save(entry)
        entry.text = "定位登录超时，尚未修复"; entry.status = .pending
        try store.save(entry)
        let restored = try JournalStore(url: url).entries()
        #expect(restored == [entry])
        #expect(restored.first?.inReport == false)
    }
    @Test func reportUsesOnlySelectedDayAndOptedInEntries() throws {
        let url = temporaryDB(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try JournalStore(url: url)
        var yesterday = Entry(text: "Review 登录模块", day: "2026-10-29"); yesterday.inReport = true
        var today = Entry(text: "开发接口", day: "2026-10-30"); today.inReport = true
        let thought = Entry(text: "明天看看缓存", day: "2026-10-29")
        for item in [yesterday, today, thought] { try store.save(item) }
        #expect(try store.reportEntries(day: "2026-10-29") == [yesterday])
    }
    @Test func blankEntryIsRejected() throws {
        let store = try JournalStore(url: temporaryDB())
        #expect(throws: (any Error).self) { try store.save(Entry(text: " \n ", day: "2026-10-30")) }
    }
    @Test func reportVersionsNeverOverwrite() throws {
        let store = try JournalStore(url: temporaryDB())
        let original = Report(day: "2026-10-29", text: "手工改好的日报")
        let replacement = Report(day: "2026-10-29", text: "重新生成的日报")
        try store.saveReport(original); try store.saveReport(replacement)
        let versions = try store.reports(day: "2026-10-29")
        #expect(versions.count == 2)
        #expect(versions.contains(original)); #expect(versions.contains(replacement))
    }
    @Test func deletionIsPersistent() throws {
        let store = try JournalStore(url: temporaryDB())
        let entry = Entry(text: "临时思路", day: "2026-10-30")
        try store.save(entry); try store.delete(id: entry.id)
        #expect(try store.entries().isEmpty)
    }
    @Test func dateRespectsLocalDay() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(Days.key(date, timeZone: TimeZone(secondsFromGMT: -3600)!) == "1969-12-31")
        #expect(Days.key(date, timeZone: TimeZone(secondsFromGMT: 28800)!) == "1970-01-01")
    }
}
