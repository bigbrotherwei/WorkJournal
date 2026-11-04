import Testing
@testable import JournalCore

struct MarkdownBlocksTests {
    @Test func parsesReportStructureAndKeepsCodeLiteral() {
        let blocks = MarkdownBlocks.parse("# 日报\n\n## 开发\n- **完成** A\n1. 排查 B\n> 尚未解决\n\n```swift\n# literal\n- code\n```\n\n---")
        #expect(blocks == [.heading(1, "日报"), .heading(2, "开发"), .item("•", "**完成** A"), .item("1.", "排查 B"), .quote("尚未解决"), .code("# literal\n- code"), .divider])
    }
    @Test func keepsParagraphsAndUnclosedCode() {
        #expect(MarkdownBlocks.parse("第一行\n第二行\n\n~~~\n**literal**") == [.paragraph("第一行\n第二行"), .code("**literal**")])
        #expect(MarkdownBlocks.parse("").isEmpty)
    }
}
