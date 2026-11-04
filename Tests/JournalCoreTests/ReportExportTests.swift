import Foundation
import Testing
@testable import JournalCore

struct ReportExportTests {
    @Test func datedReportExportsWithoutDuplicatingHeading() {
        let report = Report(day: "2026-11-03", text: "# 日报 · 2026-11-03\n\n## 开发\n- 完成 A")
        let rows = ReportArchiveDay.build(entries: [], reports: [report])
        #expect(ReportMarkdownExport.render(rows: rows, selectedDays: [report.day]) == "# 2026-11-03\n\n## 开发\n- 完成 A\n")
    }

    @Test func exportsSelectedLatestVersionsInDateOrderWithoutRewritingMarkdown() {
        var old = Report(day: "2026-10-28", text: "旧内容")
        old.createdAt = Date(timeIntervalSince1970: 1)
        let latest = Report(day: "2026-10-28", text: "## 开发\n- 完成 A\n\n```swift\nlet x = 1\n```")
        let later = Report(day: "2026-11-02", text: "- 排查 B，尚未修复")
        let excluded = Report(day: "2026-10-30", text: "不导出")
        let rows = ReportArchiveDay.build(entries: [], reports: [old, later, excluded, latest])
        let result = ReportMarkdownExport.render(rows: rows, selectedDays: [latest.day, later.day])
        #expect(result == "# 2026-10-28\n\n\(latest.text)\n\n---\n\n# 2026-11-02\n\n\(later.text)\n")
    }
    @Test func emptySelectionAndUnsavedDatesDoNotInventReports() {
        var entry = Entry(text: "仅素材", day: "2026-10-30"); entry.inReport = true
        let rows = ReportArchiveDay.build(entries: [entry], reports: [])
        #expect(ReportMarkdownExport.render(rows: rows, selectedDays: [entry.day]).isEmpty)
        #expect(ReportMarkdownExport.render(rows: rows, selectedDays: []).isEmpty)
    }
}
