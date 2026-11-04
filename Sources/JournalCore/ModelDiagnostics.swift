import Foundation
import Dispatch

public enum OllamaFailure: LocalizedError, Equatable {
    case unavailable, timeout, httpStatus(Int), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "无法连接本机 Ollama。请先安装并打开 Ollama，或在终端运行 ollama serve，然后重试。"
        case .timeout: return "本地模型请求超时。请检查 Ollama，尝试较小模型；原始记录和已有日报没有被覆盖。"
        case .httpStatus(let code): return "本地 Ollama 返回 HTTP \(code)。请检查服务版本和已下载模型，然后重试。"
        case .invalidResponse: return "本地服务返回了无法识别的数据。请确认 11434 端口运行的是兼容的 Ollama。"
        }
    }
}
public struct ModelTrialResult: Sendable, Identifiable {
    public let id = UUID()
    public let model: String
    public let category: String
    public let report: String
    public let elapsedSeconds: Double
}
public enum ModelTrial {
    public static func run(client: any LocalTextGenerating, model: String, progress: @Sendable (String) async -> Void) async throws -> ModelTrialResult {
        let start = DispatchTime.now().uptimeNanoseconds
        try Task.checkCancellation()
        let day = "2000-01-01"
        let sampleTexts = ["已完成登录模块的代码 Review，提出两项修改建议。", "正在排查接口超时，原因尚未确认，尚未修复。", "计划明天阅读缓存模块，目前尚未开始。"]
        let samples = sampleTexts.map { text -> Entry in
            var entry = Entry(text: text, day: day); entry.inReport = true; return entry
        }
        await progress("试运行 1/2 · 示例分类")
        let prompt = try Prompts.classification(entry: samples[0], categories: ["登录模块", "缓存模块"])
        let raw = try await client.generate(model: model, prompt: prompt, json: true)
        try Task.checkCancellation()
        let category = try ModelResults.category(from: raw)
        let report = try await ReportGenerator(client: client).generate(day: day, entries: samples, model: model) { detail in
            await progress("试运行 2/2 · " + detail)
        }
        try Task.checkCancellation()
        return ModelTrialResult(model: model, category: category, report: report,
                                elapsedSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
    }
}

public enum ModelResults {
    public static func category(from output: String) throws -> String {
        struct Classification: Decodable { var category: String }
        guard let decoded = try? JSONDecoder().decode(Classification.self, from: Data(output.utf8)) else {
            throw JournalError.invalid("模型没有返回有效的分类 JSON，请尝试其他本地文本模型。")
        }
        let result = decoded.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 20, !result.contains("\n"), result != "全部" else {
            throw JournalError.invalid("模型返回的分类无效，原始记录保持不变。")
        }
        return result
    }
}
