import Foundation
import Testing
@testable import JournalCore

struct DataIntegrityTests {
    func store() throws -> JournalStore { try JournalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("journal-integrity-\(UUID()).sqlite")) }
    @Test func invalidReportDateIsRejected() throws {
        let store = try store()
        #expect(throws: (any Error).self) { try store.saveReport(Report(day: "2026-02-30", text: "日报")) }
    }
    @Test func invalidEntryDateIsRejected() throws {
        let store = try store()
        #expect(throws: (any Error).self) { try store.save(Entry(text: "工作", day: "2026-02-30")) }
    }
    @Test func backupContainsRecordsAndAllVersions() throws {
        let store = try store()
        let entry = Entry(text: "备份测试", day: "2026-10-30")
        try store.save(entry)
        try store.saveReport(Report(day: entry.day, text: "版本1"))
        try store.saveReport(Report(day: entry.day, text: "版本2"))
        let json = try #require(JSONSerialization.jsonObject(with: store.exportBackup()) as? [String: Any])
        #expect((json["entries"] as? [Any])?.count == 1)
        #expect((json["reports"] as? [Any])?.count == 2)
        #expect(json["formatVersion"] as? Int == 3)
    }
    @Test func duplicateReportIDCannotOverwrite() throws {
        let store = try store()
        var report = Report(day: "2026-10-30", text: "原始版本")
        try store.saveReport(report); report.text = "覆盖尝试"
        #expect(throws: (any Error).self) { try store.saveReport(report) }
        #expect(try store.reports(day: report.day).first?.text == "原始版本")
    }
    @Test func corruptedDatabaseDoesNotSilentlyReset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID()).sqlite")
        let original = Data("this is not a database".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try JournalStore(url: url) }
        #expect(try Data(contentsOf: url) == original)
    }
}
