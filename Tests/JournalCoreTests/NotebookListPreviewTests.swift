import Foundation
import Testing
@testable import JournalCore

struct NotebookListPreviewTests {
    @Test func removesCommonMarkersAndCollapsesParagraphWhitespace() {
        #expect(NotebookListPreview.text("# 会议纪要\n\n> **讨论**\t[文档]  ") == "会议纪要 讨论 文档")
        #expect(NotebookListPreview.text("\n\t  # ** [] <>\r\n") == "")
        #expect(NotebookListPreview.text("") == "")
    }

    @Test func longImportedDocumentProducesOnlyABoundedExcerpt() {
        let source = "# 开头\n" + String(repeating: "资料 ", count: 50_000) + "不应出现在列表的尾部内容"
        let preview = NotebookListPreview.text(source)
        #expect(preview.hasPrefix("开头 资料 资料"))
        #expect(preview.count <= 240)
        #expect(preview.hasSuffix("…"))
        #expect(!preview.contains("不应出现在列表的尾部内容"))
        #expect(source.hasSuffix("不应出现在列表的尾部内容"))
    }

    @Test func ellipsisIsReservedOnlyForTruncatedContent() {
        let exact = String(repeating: "文", count: 240)
        #expect(NotebookListPreview.text(exact) == exact)
        let truncated = NotebookListPreview.text(exact + "末")
        #expect(truncated.count == 240)
        #expect(truncated.hasSuffix("…"))
        #expect(!truncated.contains("末"))
    }

    @Test func doesNotScanPastALongBlankPrefix() {
        let preview = NotebookListPreview.text(String(repeating: " ", count: 10_000) + "正文在后面")
        #expect(preview == "…")
    }

    @Test func preservesChineseAndCompleteEmoji() {
        let text = "中文 👩🏽‍💻 与 👨‍👩‍👧‍👦，cafe\u{301}。"
        #expect(NotebookListPreview.text(text) == text)
        let emoji = "👩🏽‍💻"
        let preview = NotebookListPreview.text(String(repeating: emoji, count: 500))
        #expect(preview.count <= 240)
        #expect(preview.hasSuffix("…"))
        #expect(preview.dropLast().allSatisfy { String($0) == emoji })
    }

    @Test func excludesAGraphemeThatCrossesTheSourceLimit() {
        let oversizedGrapheme = "a" + String(repeating: "\u{301}", count: 10_000)
        #expect(NotebookListPreview.text(oversizedGrapheme + "尾部") == "…")
    }
}
