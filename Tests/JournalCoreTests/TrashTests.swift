import Foundation
import Testing
@testable import JournalCore

struct TrashTests {
    @Test func deletedEntriesRemainRecoverableAndBackedUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("a.sqlite"))
        var entry = Entry(text: "待办", day: "2026-11-04")
        entry.status = .pending; entry.dueAt = Date().addingTimeInterval(3600); entry.reminderEnabled = true
        try store.save(entry)
        try store.delete(id: entry.id)
        #expect(try store.entries().isEmpty)
        #expect(try store.trashedEntries().first?.dueAt == entry.dueAt)
        #expect(try store.reportEntries(day: entry.day).isEmpty)
        let other = try JournalStore(url: root.appendingPathComponent("b.sqlite"))
        _ = try other.importBackup(store.exportBackup())
        #expect(try other.entries().isEmpty)
        #expect(try other.trashedEntries().count == 1)
        try other.restore(id: entry.id)
        #expect(try other.entries().first?.id == entry.id)
        #expect(try other.trashedEntries().isEmpty)
    }
    @Test func oldBackupCannotResurrectTrashedEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("a.sqlite"))
        let entry = Entry(text: "保留删除状态", day: "2026-11-04")
        try store.save(entry); let backup = try store.exportBackup(); try store.delete(id: entry.id)
        _ = try store.importBackup(backup)
        #expect(try store.entries().isEmpty)
        #expect(try store.trashedEntries().count == 1)
        try store.permanentlyDelete(id: entry.id)
        #expect(try store.trashedEntries().isEmpty)
    }
    @Test func permanentDeletionRejectsActiveEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("a.sqlite"))
        let entry = Entry(text: "活动记录", day: "2026-11-04"); try store.save(entry)
        #expect(throws: (any Error).self) { try store.permanentlyDelete(id: entry.id) }
        #expect(try store.entries().count == 1)
    }
}

struct SummaryStorageTests {
    @Test func summaryVersionsAndTrashRoundTripTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("a.sqlite"))
        let range = try SummaryRange(startDay: "2026-11-02", endDay: "2026-11-08")
        var summary = RangeSummary(startDay: range.startDay, endDay: range.endDay, text: "# 日期范围\n## 已完成", sourceFingerprint: "test")
        try store.saveSummary(summary)
        let firstID = summary.id
        summary.id = UUID(); summary.text += "\n- 新版本"; try store.saveSummary(summary)
        #expect(try store.summaries(startDay: range.startDay, endDay: range.endDay).count == 2)
        let other = try JournalStore(url: root.appendingPathComponent("b.sqlite"))
        let result = try other.importBackup(store.exportBackup())
        #expect(result.summaries == 2)
        #expect(try other.summaries(startDay: range.startDay, endDay: range.endDay).contains { $0.id == firstID })
        let again = try other.importBackup(store.exportBackup())
        #expect(again.summaries == 0 && again.skipped == 2)
        summary.startDay = "2026-11-09"; summary.endDay = "2026-11-02"
        #expect(throws: (any Error).self) { try other.saveSummary(summary) }
    }
    @Test func oldPayloadDefaultsOptionalFeatures() throws {
        let entry = Entry(text: "旧记录", day: "2026-11-04")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for key in ["dueAt", "reminderEnabled", "deletedAt", "images"] { json.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.dueAt == nil && !restored.reminderEnabled && restored.deletedAt == nil && restored.images.isEmpty)
    }
}
