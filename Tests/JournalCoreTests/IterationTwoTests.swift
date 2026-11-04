import Foundation
import Testing
import CSQLite
@testable import JournalCore

struct IterationTwoTests {
    func store() throws -> JournalStore { try JournalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("iteration-two-\(UUID()).sqlite")) }
    @Test func restoresMissingDataWithoutOverwritingLocalEdits() throws {
        let source = try store(), destination = try store()
        let original = Entry(text: "旧内容", day: "2026-10-29")
        let missing = Entry(text: "需要恢复", day: "2026-10-30")
        try source.save(original); try source.save(missing)
        try source.saveReport(Report(day: original.day, text: "手工日报"))
        var edited = original; edited.text = "本机新修改"
        try destination.save(edited)
        let result = try destination.importBackup(source.exportBackup())
        #expect(result.entries == 1); #expect(result.reports == 1); #expect(result.skipped == 1)
        #expect(try destination.entries().contains(edited))
        #expect(try destination.entries().contains(missing))
        #expect(try destination.reports(day: original.day).first?.text == "手工日报")
        let again = try destination.importBackup(source.exportBackup())
        #expect(again.entries == 0 && again.reports == 0 && again.skipped == 3)
    }
    @Test func invalidBackupRollsBackAllRows() throws {
        let source = try store(), destination = try store()
        try source.save(Entry(text: "有效内容", day: "2026-10-30"))
        try source.saveReport(Report(day: "2026-10-30", text: "日报"))
        var json = try #require(JSONSerialization.jsonObject(with: source.exportBackup()) as? [String: Any])
        var reports = try #require(json["reports"] as? [[String: Any]])
        reports[0]["day"] = "2026-02-30"; json["reports"] = reports
        #expect(throws: (any Error).self) { try destination.importBackup(JSONSerialization.data(withJSONObject: json)) }
        #expect(try destination.entries().isEmpty)
    }
    @Test func unknownBackupVersionIsRejected() throws {
        let store = try store()
        #expect(throws: (any Error).self) { try store.importBackup(Data(#"{"formatVersion":99,"entries":[],"reports":[]}"#.utf8)) }
    }
    @Test func categoryRenameMergesAndProtectsManualChoice() throws {
        let store = try store()
        var first = Entry(text: "登录代码Review", day: "2026-10-29"); first.category = "鉴权"
        var second = Entry(text: "登录问题", day: "2026-10-30"); second.category = "登录模块"
        try store.save(first); try store.save(second)
        #expect(try store.renameCategory(from: "鉴权", to: "登录模块") == 1)
        let rows = try store.entries()
        #expect(rows.allSatisfy { $0.category == "登录模块" })
        #expect(rows.first { $0.id == first.id }?.manualCategory == true)
        #expect(throws: (any Error).self) { try store.renameCategory(from: "登录模块", to: "  ") }
        #expect(try store.entries().count == 2)
    }
    @Test func queueSkipsAttemptedVersionsButAcceptsEditsAndNewEntries() {
        var progress = ClassificationProgress()
        var first = Entry(text: "看看缓存", day: "2026-10-30")
        #expect(progress.next(in: [first]) == first)
        progress.markAttempted(first)
        #expect(progress.next(in: [first]) == nil)
        first.text = "补充新的信息"
        #expect(progress.next(in: [first]) == first)
        let second = Entry(text: "排查超时", day: first.day)
        #expect(progress.next(in: [second]) == second)
        var manual = first; manual.manualCategory = true
        #expect(progress.next(in: [manual]) == nil)
        progress.reset()
        #expect(progress.next(in: [first]) == first)
    }
    @Test func sqlFailureMidImportRollsBackEarlierWrites() throws {
        let source = try store()
        try source.save(Entry(text: "先写入的记录", day: "2026-10-30"))
        try source.saveReport(Report(day: "2026-10-30", text: "触发存储故障"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-\(UUID()).sqlite")
        let destination = try JournalStore(url: url)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TRIGGER reject_report BEFORE INSERT ON reports BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END", nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { try destination.importBackup(source.exportBackup()) }
        #expect(try destination.entries().isEmpty)
        #expect(try destination.reports(day: "2026-10-30").isEmpty)
    }
    @Test func manualBatchResumesAfterPriorityReportEvenInPowerSaving() {
        #expect(ContinuationPolicy.next(reportWaiting: true, manualRequested: true, paused: false, powerSaving: true, hasCandidates: true) == .report)
        // Successful report completion or a preflight rejection both consume the report.
        #expect(ContinuationPolicy.next(reportWaiting: false, manualRequested: true, paused: false, powerSaving: true, hasCandidates: true) == .manualClassification)
        #expect(ContinuationPolicy.next(reportWaiting: false, manualRequested: true, paused: true, powerSaving: true, hasCandidates: true) == .idle)
        #expect(ContinuationPolicy.next(reportWaiting: false, manualRequested: false, paused: false, powerSaving: true, hasCandidates: true) == .idle)
        #expect(ContinuationPolicy.next(reportWaiting: false, manualRequested: false, paused: false, powerSaving: false, hasCandidates: true) == .backgroundClassification)
        #expect(ContinuationPolicy.next(reportWaiting: false, manualRequested: true, paused: false, powerSaving: false, hasCandidates: false) == .idle)
    }
}
