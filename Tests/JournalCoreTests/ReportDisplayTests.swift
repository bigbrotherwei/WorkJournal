import Foundation
import Testing
@testable import JournalCore
struct ReportDisplayTests {
    @Test func emptyCachedDraftCannotHideSavedReport() {
        let report = Report(day: "2026-10-30", text: "已保存日报")
        #expect(ReportDisplay.content(saved: report, draft: ReportDraft(text: " \n", sourceFingerprint: nil)).text == report.text)
        #expect(ReportDisplay.content(saved: report, draft: ReportDraft(text: "未保存修改", sourceFingerprint: nil)).text == "未保存修改")
        #expect(ReportDisplay.content(saved: nil, draft: nil).text.isEmpty)
    }
}
