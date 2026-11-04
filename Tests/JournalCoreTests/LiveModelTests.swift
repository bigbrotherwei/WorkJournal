import Foundation
import Testing
@testable import JournalCore

// Explicit opt-in only. Uses synthetic examples, never opens JournalStore.
struct LiveModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKJOURNAL_LIVE_MODEL"] != nil))
    func installedModelCompletesSampleTrial() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["WORKJOURNAL_LIVE_MODEL"])
        let client = OllamaClient()
        #expect(try await client.models().contains { $0.name == model && $0.isLocal })
        let result = try await ModelTrial.run(client: client, model: model) { print($0) }
        #expect(!result.category.isEmpty)
        #expect(!result.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("LIVE MODEL: \(model)\nELAPSED: \(result.elapsedSeconds) s\nCATEGORY: \(result.category)\nREPORT:\n\(result.report)")
        // Successful protocol handling does not establish factual accuracy; review the printed report.
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKJOURNAL_LIVE_MODEL"] != nil))
    func relatedNotesBecomeThreeWorkItems() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["WORKJOURNAL_LIVE_MODEL"])
        let day = "2000-01-01"
        let texts = ["阅读登录模块代码。", "梳理登录模块的 token 校验流程。", "发现登录模块 token 过期后未正确清理，尚未修复。", "阅读缓存模块的淘汰策略。", "梳理缓存模块的 LRU 数据结构，计划明天补测试，尚未开始。", "Review 导出模块代码，发现文件名校验遗漏。", "对导出模块提出文件名校验修改建议，等待作者修改。"]
        let entries = texts.map { text -> Entry in
            var entry = Entry(text: text, day: day); entry.inReport = true; return entry
        }
        let client = OllamaClient()
        let report = try await ReportGenerator(client: client).generate(day: day, entries: entries, model: model) { _ in }
        let merge = try await client.generate(model: model, prompt: ReportBatchPlanner.mergePrompt(day: day, summaries: [
            "阅读登录模块代码，梳理 token 校验流程；阅读缓存模块淘汰策略；Review 导出模块，发现文件名校验遗漏。",
            "发现登录模块 token 过期后未正确清理，尚未修复；梳理缓存模块 LRU 数据结构，计划明天补测试，尚未开始；对导出模块提出文件名校验修改建议，等待作者修改。"
        ]), json: false)
        for (path, output) in [("single batch", report), ("merge", merge)] {
            print("CONSOLIDATED \(path):\n\(output)")
            let items = workItems(output)
            // Related notes share a work-item heading; details remain separate bullets.
            #expect(items.count == 3)
            #expect(bullets(output).count >= 4 && bullets(output).count <= 6)
            for topic in ["登录", "缓存", "导出"] {
                #expect(items.filter { $0.contains(topic) }.count == 1)
            }
            #expect(output.contains("尚未修复"))
            #expect((output.contains("计划明天") || output.contains("计划明日")) && output.contains("尚未开始"))
            #expect(output.contains("等待作者"))
            #expect(!output.contains("支付") && !output.contains("搜索接口"))
        }
        // Review the printed report for preservation of unresolved/planned states.
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKJOURNAL_LIVE_MODEL"] != nil))
    func independentProblemsInSameModuleStaySeparate() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["WORKJOURNAL_LIVE_MODEL"])
        let day = "2000-01-01"
        let entries = ["排查导出模块的文件名校验遗漏，已定位原因，尚未修复。", "另一个独立任务：优化导出模块大文件的内存占用，正在分析，尚未完成。"].map { text -> Entry in
            var entry = Entry(text: text, day: day); entry.inReport = true; entry.category = "导出模块"; return entry
        }
        let output = try await ReportGenerator(client: OllamaClient()).generate(day: day, entries: entries, model: model) { _ in }
        print("INDEPENDENT ITEMS:\n\(output)")
        let items = workItems(output)
        #expect(items.count == 2)
        #expect(items.contains { $0.contains("文件名") && !$0.contains("内存") })
        #expect(items.contains { $0.contains("内存") && !$0.contains("文件名") })
        #expect(output.contains("尚未修复") && output.contains("尚未完成"))
    }

    private func workItems(_ report: String) -> [String] {
        var items: [String] = []
        for line in report.components(separatedBy: .newlines) {
            if line.hasPrefix("### ") { items.append(line) }
            else if !line.hasPrefix("## "), !items.isEmpty { items[items.count - 1] += "\n" + line }
        }
        return items
    }

    private func bullets(_ report: String) -> [String] {
        report.components(separatedBy: .newlines).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("- ") || line.hasPrefix("* ")
        }
    }

}
