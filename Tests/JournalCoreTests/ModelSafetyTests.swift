import Foundation
import Testing
@testable import JournalCore
struct ModelSafetyTests {
    @Test func rejectsCloudModels() throws {
        let cloud = try JSONDecoder().decode(LocalModel.self, from: Data(#"{"name":"example:cloud"}"#.utf8))
        let remote = try JSONDecoder().decode(LocalModel.self, from: Data(#"{"name":"alias","remote_host":"https://ollama.com"}"#.utf8))
        let local = try JSONDecoder().decode(LocalModel.self, from: Data(#"{"name":"local:4b"}"#.utf8))
        #expect(!cloud.isLocal); #expect(!remote.isLocal); #expect(local.isLocal)
    }
    @Test func promptRejectsEmptyReportAndFiltersOtherDays() throws {
        #expect(throws: (any Error).self) { try Prompts.report(day: "2026-10-29", entries: []) }
        var yes = Entry(text: "昨天已完成Review", day: "2026-10-29"); yes.inReport = true
        var no = Entry(text: "今天的机密记录", day: "2026-10-30"); no.inReport = true
        let prompt = try Prompts.report(day: "2026-10-29", entries: [yes, no])
        #expect(prompt.contains(yes.text)); #expect(!prompt.contains(no.text))
    }
    @Test func changingReportSourcesInvalidatesResult() {
        var entry = Entry(text: "尚未完成", day: "2026-10-30"); entry.inReport = true
        var edited = entry; edited.text = "已经完成"
        #expect(!Prompts.sameReportSources(day: entry.day, original: [entry], current: [edited]))
        #expect(!Prompts.sameReportSources(day: entry.day, original: [entry], current: []))
        edited = entry; edited.inReport = false
        #expect(!Prompts.sameReportSources(day: entry.day, original: [entry], current: [edited]))
        let unrelated = Entry(text: "普通思路", day: entry.day)
        #expect(Prompts.sameReportSources(day: entry.day, original: [entry], current: [unrelated, entry]))
    }
}
