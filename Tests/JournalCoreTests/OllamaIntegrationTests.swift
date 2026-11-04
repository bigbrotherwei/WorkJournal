import Foundation
import Testing
@testable import JournalCore

private final class RequestTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func add(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return requests.compactMap { $0.url?.path } }
}
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    static func register(_ handler: @escaping Handler) -> String {
        lock.lock(); defer { lock.unlock() }
        let id = UUID().uuidString; handlers[id] = handler; return id
    }
    static func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: id) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.value(forHTTPHeaderField: "X-Test-Scenario") ?? ""]; Self.lock.unlock()
        do {
            guard let handler, let url = request.url else { throw URLError(.unsupportedURL) }
            let (status, text) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
struct OllamaIntegrationTests {
    private func fixture(_ handler: @escaping StubProtocol.Handler) -> (OllamaClient, String) {
        let id = StubProtocol.register(handler), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]; config.httpAdditionalHeaders = ["X-Test-Scenario": id]
        return (OllamaClient(configuration: config), id)
    }
    @Test func diagnosesConnectionFailureAndBadResponses() async {
        let fixtures: [(StubProtocol.Handler, OllamaFailure)] = [
            ({ _ in throw URLError(.cannotConnectToHost) }, .unavailable),
            ({ _ in throw URLError(.timedOut) }, .timeout),
            ({ _ in (503, "unavailable") }, .httpStatus(503)),
            ({ _ in (200, "not JSON") }, .invalidResponse)
        ]
        for (handler, expected) in fixtures {
            let (client, id) = fixture(handler); defer { StubProtocol.remove(id) }
            do { _ = try await client.models(); Issue.record("应返回诊断错误") }
            catch { #expect(error as? OllamaFailure == expected) }
        }
    }
    @Test func neverSendsContentWhenModelPointsToCloud() async {
        for cloudInTags in [true, false] {
            let trace = RequestTrace()
            let (client, id) = fixture { request in
                trace.add(request)
                if request.url?.path == "/api/tags" {
                    return (200, cloudInTags ? #"{"models":[{"name":"alias","remote_host":"https://ollama.com"}]}"# : #"{"models":[{"name":"alias"}]}"#)
                }
                return (200, #"{"remote_host":"https://ollama.com"}"#)
            }
            defer { StubProtocol.remove(id) }
            do { _ = try await client.generate(model: "alias", prompt: "私有工作内容"); Issue.record("远端模型应拒绝") }
            catch { #expect(!trace.paths.contains("/api/generate")) }
        }
    }
    @Test func embeddingOnlyModelNeverReceivesWorkContent() async {
        let trace = RequestTrace()
        let (client, id) = fixture { request in
            trace.add(request)
            return (200, request.url?.path == "/api/tags" ? #"{"models":[{"name":"embed"}]}"# : #"{"capabilities":["embedding"]}"#)
        }
        defer { StubProtocol.remove(id) }
        do { _ = try await client.generate(model: "embed", prompt: "工作内容"); Issue.record("应拒绝非文本模型") }
        catch { #expect(trace.paths == ["/api/tags", "/api/show"]) }
    }
    @Test func invalidClassificationStopsTrialBeforeReport() async {
        let client = InvalidTrialGenerator()
        do { _ = try await ModelTrial.run(client: client, model: "local", progress: { _ in }); Issue.record("应拒绝无效分类") }
        catch { #expect(await client.calls == 1) }
    }
    @Test func classificationRequiresCategorySchemaInsteadOfGenericJSON() async throws {
        let (client, id) = fixture { request in
            if request.url?.path == "/api/tags" { return (200, #"{"models":[{"name":"local"}]}"#) }
            if request.url?.path == "/api/show" { return (200, #"{"capabilities":["completion"]}"#) }
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let schema = body?["format"] as? [String: Any]
            #expect(schema?["required"] as? [String] == ["category"])
            #expect(schema?["additionalProperties"] as? Bool == false)
            let output = schema == nil ? #"{"记录":"回显输入"}"# : #"{"category":"登录模块"}"#
            let response = try JSONSerialization.data(withJSONObject: ["response": output, "done": true, "done_reason": "stop"])
            return (200, String(decoding: response, as: UTF8.self))
        }
        defer { StubProtocol.remove(id) }
        #expect(try await client.classify(model: "local", entry: Entry(text: "Review 登录模块", day: "2026-10-30"), categories: ["登录模块"]) == "登录模块")
    }
    @Test func localProtocolRoundTripAndShortDiagnosticTimeout() async throws {
        let trace = RequestTrace()
        let (client, id) = fixture { request in
            trace.add(request)
            #expect(request.url?.host == "127.0.0.1")
            switch request.url?.path {
            case "/api/tags":
                #expect(request.timeoutInterval <= 10)
                return (200, #"{"models":[{"name":"local"}]}"#)
            case "/api/show": return (200, #"{"capabilities":["completion"]}"#)
            default: return (200, #"{"response":"完整日报","done":true,"done_reason":"stop"}"#)
            }
        }
        defer { StubProtocol.remove(id) }
        #expect(try await client.generate(model: "local", prompt: "示例") == "完整日报")
        #expect(trace.paths == ["/api/tags", "/api/show", "/api/generate"])
    }
    @Test func trialRunsClassificationAndReportWithoutJournalAccess() async throws {
        let client = TrialGenerator()
        let result = try await ModelTrial.run(client: client, model: "local", progress: { _ in })
        #expect(result.category == "登录模块")
        #expect(result.report.contains("尚未修复"))
        #expect(result.model == "local")
        #expect(await client.calls == [true, false])
        #expect(result.elapsedSeconds >= 0)
    }
}
private actor TrialGenerator: LocalTextGenerating {
    var calls: [Bool] = []
    func generate(model: String, prompt: String, json: Bool) async throws -> String {
        calls.append(json)
        return json ? #"{"category":"登录模块"}"# : "完成 Review；超时问题尚未修复；缓存优化仅为计划。"
    }
}

private actor InvalidTrialGenerator: LocalTextGenerating {
    var calls = 0
    func generate(model: String, prompt: String, json: Bool) async throws -> String {
        calls += 1
        return #"{"category":"全部"}"#
    }
}
