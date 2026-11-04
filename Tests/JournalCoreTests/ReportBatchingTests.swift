import Foundation
import Testing
@testable import JournalCore

private actor RecordingGenerator: LocalTextGenerating {
    var prompts: [String] = []
    var failAt: Int?
    var cancelAt: Int?
    let output: String?
    init(failAt: Int? = nil, cancelAt: Int? = nil, output: String? = nil) { self.failAt = failAt; self.cancelAt = cancelAt; self.output = output }
    func generate(model: String, prompt: String, json: Bool) async throws -> String {
        prompts.append(prompt)
        if prompts.count == failAt { throw JournalError.invalid("模拟中途失败") }
        if prompts.count == cancelAt { throw CancellationError() }
        if let output { return output }
        return "第\(prompts.count)批：排查尚未完成，不应写成已修复。"
    }
    var count: Int { prompts.count }
}
struct ReportBatchingTests {
    @Test func templateIsAppliedOnceAfterAllBatchesAndNeverSentToModel() async throws {
        let entry = longEntry(), client = RecordingGenerator()
        let template = ReportTemplate(opening: "固定抬头-测试标识", closing: "固定署名-测试标识")
        let result = try await ReportGenerator(client: client).generate(day: entry.day, entries: [entry], model: "local", template: template, progress: { _ in })
        #expect(result.hasPrefix("# \(entry.day)\n\n" + template.opening + "\n\n"))
        #expect(result.hasSuffix("\n\n" + template.closing))
        #expect(result.components(separatedBy: template.opening).count == 2)
        #expect(result.components(separatedBy: template.closing).count == 2)
        #expect(await client.count > 1)
        #expect(await client.prompts.allSatisfy { !$0.contains(template.opening) && !$0.contains(template.closing) })
    }

    @Test func generatedReportAlwaysHasSelectedDayHeading() async throws {
        var entry = Entry(text: "排查仍在进行", day: "2026-11-03"); entry.inReport = true
        let body = "## 故障排除\n- 排查仍在进行。"
        for output in [body, "# 日报 · 2026-11-03\n\n" + body, "# 2026-11-03\n\n" + body] {
            let result = try await ReportGenerator(client: RecordingGenerator(output: output)).generate(day: entry.day, entries: [entry], model: "local", progress: { _ in })
            #expect(result == "# 2026-11-03\n\n" + body)
        }
    }

    func longEntry() -> Entry {
        var entry = Entry(text: String(repeating: "检查登录模块👨‍👩‍👧‍👦：仍在排查\"\\\n", count: 1100), day: "2026-10-30")
        entry.inReport = true; return entry
    }
    @Test func splittingPreservesEveryCharacterAndPromptBudget() throws {
        let entry = longEntry()
        var unrelated = entry; unrelated.id = UUID(); unrelated.day = "2026-10-29"
        let batches = try ReportBatchPlanner.batches(day: entry.day, entries: [entry, unrelated])
        #expect(batches.count > 1)
        let fragments = batches.flatMap { $0 }
        #expect(fragments.allSatisfy { $0.sourceID == entry.id })
        #expect(fragments.map(\.text).joined() == entry.text)
        #expect(fragments.map(\.part) == Array(1...max(1, fragments.count)))
        for batch in batches { #expect(try ReportBatchPlanner.prompt(day: entry.day, fragments: batch).utf8.count <= ReportBatchPlanner.maxPromptBytes) }
    }
    @Test func multipleBatchesProduceOneCombinedResult() async throws {
        let entry = longEntry(), client = RecordingGenerator()
        let result = try await ReportGenerator(client: client).generate(day: entry.day, entries: [entry], model: "local", progress: { _ in })
        let leaves = try ReportBatchPlanner.batches(day: entry.day, entries: [entry]).count
        #expect(await client.count == leaves + 1)
        #expect(!result.isEmpty)
    }
    @Test func failureAndCancellationStopLaterRequests() async {
        let entry = longEntry()
        for cancel in [false, true] {
            let client = RecordingGenerator(failAt: cancel ? nil : 2, cancelAt: cancel ? 2 : nil)
            do {
                _ = try await ReportGenerator(client: client).generate(day: entry.day, entries: [entry], model: "local", progress: { _ in })
                Issue.record("应停止生成并返回错误")
            } catch { #expect(await client.count == 2) }
        }
    }
    @Test func rejectsTruncatedUnfinishedAndEmptyResponses() throws {
        for data in [#"{"response":"不完整","done":true,"done_reason":"length"}"#, #"{"response":"未结束","done":false}"#, #"{"response":"  ","done":true,"done_reason":"stop"}"#] {
            let response = try JSONDecoder().decode(GenerationResponse.self, from: Data(data.utf8))
            #expect(throws: (any Error).self) { try response.validated() }
        }
        let response = try JSONDecoder().decode(GenerationResponse.self, from: Data(#"{"response":"完整结果","done":true,"done_reason":"stop"}"#.utf8))
        #expect(try response.validated() == "完整结果")
    }
    @Test func largeSummariesMergeThroughMultipleBoundedRounds() async throws {
        let entry = longEntry()
        let client = RecordingGenerator(output: String(repeating: "事实", count: 450))
        _ = try await ReportGenerator(client: client).generate(day: entry.day, entries: [entry], model: "local", progress: { _ in })
        let leaves = try ReportBatchPlanner.batches(day: entry.day, entries: [entry]).count
        #expect(await client.count > leaves + 1)
        #expect(await client.prompts.allSatisfy { $0.utf8.count <= ReportBatchPlanner.maxPromptBytes })
    }
    @Test func oversizedSummariesFailRatherThanTruncateOrLoop() async {
        let entry = longEntry(), client = RecordingGenerator(output: String(repeating: "太长", count: 3000))
        do {
            _ = try await ReportGenerator(client: client).generate(day: entry.day, entries: [entry], model: "local", progress: { _ in })
            Issue.record("过长摘要应明确失败")
        } catch { #expect(await client.count <= ReportBatchPlanner.maxBatches) }
    }
    @Test func taskCancellationStopsAfterActiveRequest() async throws {
        let signal = AsyncStream<Void>.makeStream()
        let client = CancellableGenerator(started: signal.continuation)
        let entry = longEntry()
        let task = Task { try await ReportGenerator(client: client).generate(day: entry.day, entries: [entry], model: "local", progress: { _ in }) }
        for await _ in signal.stream { break }
        task.cancel()
        do { _ = try await task.value; Issue.record("取消应停止生成") }
        catch is CancellationError { #expect(await client.count == 1) }
    }
}

private actor CancellableGenerator: LocalTextGenerating {
    let started: AsyncStream<Void>.Continuation
    var count = 0
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    func generate(model: String, prompt: String, json: Bool) async throws -> String {
        count += 1; started.yield(()); started.finish()
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return "摘要"
    }
}
