import Foundation
import Testing
@testable import JournalCore

struct RangeSummaryTests {
    @Test func inclusiveMondayWeekAndValidation() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        let date = ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!
        let range = SummaryRange.currentWeek(containing: date, timeZone: zone)
        #expect(range.startDay == "2026-11-02")
        #expect(range.endDay == "2026-11-08")
        #expect(range.contains(day: range.endDay))
        #expect(SummaryRange.previousWeek(containing: date, timeZone: zone).startDay == "2026-10-26")
        #expect(throws: (any Error).self) { try SummaryRange(startDay: "2026-02-30", endDay: "2026-03-01") }
        #expect(throws: (any Error).self) { try SummaryRange(startDay: "2026-11-05", endDay: "2026-11-04") }
    }
    @Test func filtersTrashAndFingerprintChangesWithFacts() throws {
        let range = try SummaryRange(startDay: "2026-11-01", endDay: "2026-11-04")
        var entry = Entry(text: "支付进展", day: "2026-11-04"); entry.inReport = true
        let first = RangeSummaryGenerator.sourceFingerprint(range: range, entries: [entry], includeAllRecords: false)
        var changed = entry; changed.status = .done
        #expect(first != RangeSummaryGenerator.sourceFingerprint(range: range, entries: [changed], includeAllRecords: false))
        changed = entry; changed.deletedAt = Date()
        #expect(first != RangeSummaryGenerator.sourceFingerprint(range: range, entries: [changed], includeAllRecords: false))
        #expect(RangeSummaryGenerator.selectedEntries(range: range, entries: [changed], includeAllRecords: true).isEmpty)
        entry.inReport = false
        #expect(RangeSummaryGenerator.selectedEntries(range: range, entries: [entry], includeAllRecords: false).isEmpty)
        #expect(RangeSummaryGenerator.selectedEntries(range: range, entries: [entry], includeAllRecords: true).count == 1)
    }
    @Test func cancellationStopsBeforeNextBatchWithoutCandidate() async throws {
        let range = try SummaryRange(startDay: "2026-11-01", endDay: "2026-11-04")
        var entry = Entry(text: String(repeating: "支付模块进展。", count: 3000), day: "2026-11-04"); entry.inReport = true
        let client = CancellingSummaryMock()
        let task = Task { try await RangeSummaryGenerator(client: client).generate(range: range, entries: [entry], model: "mock") }
        do { _ = try await task.value; Issue.record("取消后不应返回可保存的总结") }
        catch is CancellationError { }
        catch { Issue.record("预期 CancellationError，实际为 \(error)") }
        #expect(await client.count == 1)
    }
    @Test func whitespaceOnlySourcesRejectBeforeModelRequest() async throws {
        let range = try SummaryRange(startDay: "2026-11-01", endDay: "2026-11-04")
        var entry = Entry(text: "  \n  ", day: "2026-11-04"); entry.inReport = true
        let client = SummaryMock()
        await #expect(throws: (any Error).self) {
            try await RangeSummaryGenerator(client: client).generate(range: range, entries: [entry], model: "mock")
        }
        #expect(await client.prompts.isEmpty)
    }
    @Test func boundedDatedRawSourcesAndTemplateOnce() async throws {
        let range = try SummaryRange(startDay: "2026-11-01", endDay: "2026-11-04")
        var entry = Entry(text: String(repeating: "支付模块尚未修复。", count: 2000), day: "2026-11-04"); entry.inReport = true
        let client = SummaryMock()
        let result = try await RangeSummaryGenerator(client: client).generate(range: range, entries: [entry], model: "mock", template: ReportTemplate(opening: "固定开头"), progress: { _ in })
        let prompts = await client.prompts
        #expect(prompts.count > 1)
        #expect(prompts.allSatisfy { $0.utf8.count <= ReportBatchPlanner.maxPromptBytes })
        #expect(prompts.first!.contains("2026-11-04"))
        #expect(prompts.allSatisfy { !$0.contains("固定开头") })
        #expect(prompts.allSatisfy { $0.contains("后续明确文字证据") && $0.contains("不使用“昨日”") && $0.contains("不同子任务的未解决状态必须保留") })
        #expect(prompts.last!.contains("分批摘要综合"))
        #expect(result.text.components(separatedBy: "固定开头").count == 2)
        #expect(result.text.hasPrefix("# 2026-11-01 — 2026-11-04"))
    }
}
private actor SummaryMock: LocalTextGenerating {
    var prompts: [String] = []
    func generate(model: String, prompt: String, json: Bool) async throws -> String {
        prompts.append(prompt); return "## 开发\n### 支付模块\n- 尚未修复。"
    }
}

private actor CancellingSummaryMock: LocalTextGenerating {
    var count = 0
    func generate(model: String, prompt: String, json: Bool) async throws -> String {
        count += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return "不应被保存的部分摘要"
    }
}
