import Foundation
import Testing
@testable import JournalCore

struct ReportTemplateTests {
    let day = "2026-11-04"
    let body = "## 开发\n- 完成代码检查"

    @Test func emptyTemplateKeepsDateAndBodyUnchanged() {
        #expect(ReportTemplate().render(day: day, body: body) == "# \(day)\n\n" + body)
        #expect(ReportTemplate(opening: " \n", closing: "\t").render(day: day, body: body) == "# \(day)\n\n" + body)
    }
    @Test func templatePreservesLiteralMarkdownAndMultilineText() {
        let template = ReportTemplate(opening: "各位好：\n\n**项目：A**", closing: "谢谢\n署名：小王")
        #expect(template.render(day: day, body: body) == "# \(day)\n\n各位好：\n\n**项目：A**\n\n" + body + "\n\n谢谢\n署名：小王")
    }
    @Test func eitherEndCanBeConfiguredIndependentlyAndDateIsNotDuplicated() {
        let dated = "# \(day)\n\n" + body
        #expect(ReportTemplate(opening: "开头").render(day: day, body: dated) == "# \(day)\n\n开头\n\n" + body)
        #expect(ReportTemplate(closing: "结尾").render(day: day, body: dated) == dated + "\n\n结尾")
    }
    @Test func exportingSavedTemplateDoesNotDuplicateOrReapplyIt() {
        let text = ReportTemplate(opening: "固定开头", closing: "固定结尾").render(day: day, body: body)
        let rows = ReportArchiveDay.build(entries: [], reports: [Report(day: day, text: text)])
        #expect(ReportMarkdownExport.render(rows: rows, selectedDays: [day]) == text + "\n")
    }
}
