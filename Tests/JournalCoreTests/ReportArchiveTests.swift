import Foundation
import Testing
@testable import JournalCore

struct ReportArchiveTests {
    @Test func archiveMergesByAssignedDayAndKeepsReportWithoutSources() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try JournalStore(url: url)
        var entry = Entry(text: "补写昨天", day: "2026-10-29"); entry.inReport = true
        try store.save(entry)
        try store.save(Entry(text: "普通思路", day: "2026-10-30"))
        try store.saveReport(Report(day: "2026-10-28", text: "没有素材的历史日报"))
        let rows = try store.reportArchive()
        #expect(rows.map(\.day) == ["2026-10-29", "2026-10-28"])
        #expect(rows[0].sourceCount == 1 && rows[0].versionCount == 0)
        #expect(rows[0].state == .unsaved)
        #expect(rows[1].sourceCount == 0 && rows[1].versionCount == 1)
        #expect(rows[1].state == .unverified)
    }
    @Test func latestVersionControlsFreshnessAndAllVersionsRemain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try JournalStore(url: url)
        var entry = Entry(text: "Review", day: "2026-10-29"); entry.inReport = true
        try store.save(entry)
        var old = Report(day: entry.day, text: "旧版"); old.createdAt = Date(timeIntervalSince1970: 1)
        let latest = Report(day: entry.day, text: "新版", sourceFingerprint: ReportFreshness.fingerprint(day: entry.day, entries: [entry]))
        try store.saveReport(latest); try store.saveReport(old)
        var row = try #require(store.reportArchive().first)
        #expect(row.versionCount == 2 && row.state == .current)
        #expect(row.latestReport == latest)
        entry.text = "Review 后补充"; try store.save(entry)
        row = try #require(store.reportArchive().first)
        #expect(row.state == .changed)
        try store.delete(id: entry.id)
        #expect(try store.reportArchive().first?.state == .changed)
        #expect(try store.reports(day: entry.day).count == 2)
    }
    @Test func emptyArchiveHasNoInventedDates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try JournalStore(url: url).reportArchive().isEmpty)
    }
}
