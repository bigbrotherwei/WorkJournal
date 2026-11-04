import Foundation
import Testing
@testable import JournalCore

struct LiveRangeSummaryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKJOURNAL_LIVE_MODEL"] != nil))
    func syntheticCrossDaySummary() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["WORKJOURNAL_LIVE_MODEL"])
        let range = try SummaryRange(startDay: "2000-01-03", endDay: "2000-01-09")
        let rows = [("2000-01-03", "排查缓存模块重复刷新问题，已定位原因，尚未修复。"),
                    ("2000-01-04", "修复昨天定位的缓存模块重复刷新问题，回归测试通过。"),
                    ("2000-01-05", "Review 支付模块，发现回调验签遗漏，等待作者修改，尚未修复。")]
        let entries = rows.map { day, text -> Entry in var e = Entry(text: text, day: day); e.inReport = true; return e }
        let output = try await RangeSummaryGenerator(client: OllamaClient()).generate(range: range, entries: entries, model: model)
        #expect(output.text.hasPrefix("# 2000-01-03 — 2000-01-09"))
        #expect(output.text.contains("缓存") && output.text.contains("验签"))
        #expect(output.text.contains("等待作者") || output.text.contains("待作者"))
        let cacheSections = output.text.components(separatedBy: "###").filter { $0.contains("缓存") }
        let cache = cacheSections.joined(separator: "\n")
        #expect(!cache.isEmpty)
        #expect(cache.contains("修复") && cache.contains("回归"))
        #expect(!cache.contains("尚未修复") && !cache.contains("未修复"))
        #expect(!output.text.contains("昨天") && !output.text.contains("昨日"))
        #expect(output.text.contains("尚未修复") || output.text.contains("等待作者") || output.text.contains("待作者"))
        print("SYNTHETIC RANGE SUMMARY:\n" + output.text)
    }
}
