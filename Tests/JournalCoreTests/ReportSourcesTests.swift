import Foundation
import Testing
@testable import JournalCore

struct ReportSourcesTests {
    func entry(_ text: String = "完成导入验证") -> Entry {
        var value = Entry(text: text, day: "2026-11-18"); value.inReport = true; return value
    }
    @Test func stripsMarkersAndRetainsOnlyAllowedSnapshots() throws {
        let a = entry(), b = entry("补充目录示例"), unknown = UUID()
        let raw = "## 开发\n- 完成导入并补充示例。 [[source:\(a.id),\(b.id),\(unknown)]]\n- 下一步整理说明。 [[source:garbage]]"
        let result = ReportProvenance.build(body: raw, entries: [a,b], day: a.day, template: ReportTemplate())
        #expect(!result.text.contains("[[source:"))
        #expect(result.provenance.sources.count == 2)
        #expect(result.provenance.sources(forPoint: "完成导入并补充示例。", currentText: result.text).map(\.id) == [a.id,b.id])
        #expect(result.provenance.sources(forPoint: "下一步整理说明。", currentText: result.text).isEmpty)
        #expect(result.provenance.sources(forPoint: "完成导入并补充示例。", currentText: result.text + "改写").isEmpty)
    }
    @Test func missingCitationsRemainUnassignedAndSnapshotsDoNotChange() {
        var a = entry(); let result = ReportProvenance.build(body: "- 完成导入验证", entries: [a], day: a.day, template: ReportTemplate())
        a.text = "后来改了原文"
        #expect(result.provenance.sources[0].text == "完成导入验证")
        #expect(result.provenance.sources(forPoint: "完成导入验证", currentText: result.text).isEmpty)
    }
    @Test func duplicatePointDoesNotClaimAmbiguousSourcesAndTemplateIsNotParsed() {
        let a=entry(), b=entry("另一项")
        let result=ReportProvenance.build(body:"- 相同文字 [[source:\(a.id)]]\n- 相同文字 [[source:\(b.id)]]",entries:[a,b],day:a.day,template:ReportTemplate(opening:"固定开头",closing:"固定结尾"))
        #expect(result.provenance.sources(forPoint:"相同文字",currentText:result.text).isEmpty)
        #expect(result.text.hasSuffix("固定结尾"))
    }
    @Test func templateBulletNeverBorrowsModelAttribution() {
        let a = entry()
        let result = ReportProvenance.build(body: "- 完成同步 [[source:\(a.id)]]", entries: [a], day: a.day, template: ReportTemplate(opening: "- 完成同步", closing: ""))
        #expect(result.provenance.sources(forPoint: "完成同步", currentText: result.text).isEmpty)
    }
    @Test func legacyReportsAndEntriesDecodeWithoutProvenance() throws {
        let a=entry(); var json=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(a)) as? [String:Any]); json.removeValue(forKey:"sourceNoteID"); json.removeValue(forKey:"sourceNoteTitle")
        let decoded=try JSONDecoder().decode(Entry.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(decoded.sourceNoteID == nil)
        let report=Report(day:a.day,text:"旧日报"); let loaded=try JSONDecoder().decode(Report.self,from:JSONEncoder().encode(report)); #expect(loaded.provenance == nil)
    }
    @Test func sourceLinksAndProvenanceSurviveBackupAndHistoryLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try JournalStore(url: root.appendingPathComponent("original.sqlite"))
        var a = entry(); a.sourceNoteID = UUID(); a.sourceNoteTitle = "模块阅读"; a.status = .pending
        try original.save(a)
        let result = ReportProvenance.build(body: "- 完成验证 [[source:\(a.id)]]", entries: [a], day: a.day, template: ReportTemplate())
        let report = Report(day: a.day, text: result.text, provenance: result.provenance)
        try original.saveReport(report)
        try original.delete(id: a.id)
        let restored = try JournalStore(url: root.appendingPathComponent("restored.sqlite"))
        _ = try restored.importBackup(original.exportBackup())
        let archived = try #require(restored.reports(day: a.day).first)
        #expect(archived.provenance == result.provenance)
        #expect(archived.provenance?.sources(forPoint: "完成验证", currentText: archived.text).count == 1)
        let trashed = try #require(restored.trashedEntries().first)
        #expect(trashed.sourceNoteID == a.sourceNoteID)
        #expect(trashed.sourceNoteTitle == "模块阅读")
    }
    @Test func multipleBatchesKeepOnlyRealInputIDs() async throws {
        let a = entry(String(repeating: "完成边界验证。", count: 1500))
        let b = entry("排查数据导入")
        let client = SourceGenerator(id: a.id)
        #expect(try ReportBatchPlanner.batches(day: a.day, entries: [a,b]).count > 1)
        let report = try await ReportGenerator(client: client).generateReport(day: a.day, entries: [a,b], model: "test", progress: {_ in})
        #expect(report.provenance?.sources.count == 2)
        #expect(report.provenance?.sources(forPoint: "完成导入验证。", currentText: report.text).map(\.id) == [a.id])
        #expect(!report.text.contains("[[source:"))
    }
    @Test func recurringTaskKeepsItsSourceNoteLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("journal.sqlite"))
        var task = entry("笔记里的重复检查"); task.status = .pending; task.recurrence = .daily; task.dueAt = Date().addingTimeInterval(3600)
        task.sourceNoteID = UUID(); task.sourceNoteTitle = "模块阅读"
        try store.save(task)
        task = try #require(store.entries().first)
        task.status = .done; try store.save(task)
        let next = try #require(store.entries().first(where: { $0.status == .pending }))
        #expect(next.sourceNoteID == task.sourceNoteID)
        #expect(next.sourceNoteTitle == task.sourceNoteTitle)
    }
    @Test func generatedDailyAndWeeklyCarrySourcesAndCleanText() async throws {
        let a=entry(); let client=SourceGenerator(id:a.id)
        let report=try await ReportGenerator(client:client).generateReport(day:a.day,entries:[a],model:"test",progress:{_ in})
        #expect(report.provenance?.sources.first?.id == a.id)
        #expect(!report.text.contains("[[source:"))
        let range=try SummaryRange(startDay:a.day,endDay:a.day)
        let weekly=try await RangeSummaryGenerator(client:client).generate(range:range,entries:[a],model:"test")
        #expect(weekly.provenance?.sources.first?.id == a.id)
        #expect(!weekly.text.contains("[[source:"))
    }
}
private struct SourceGenerator: LocalTextGenerating {
    let id:UUID
    func generate(model:String,prompt:String,json:Bool) async throws -> String {
        #expect(prompt.contains("[[source:"))
        return "## 开发\n- 完成导入验证。 [[source:\(id)]]"
    }
}
