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

    @Test func tableAlignmentAndShortRows() {
        #expect(MarkdownBlocks.parse("| 工作 | 状态 | 数量 |\n| :--- | :---: | ---: |\n| 开发 | 完成 | 2 |\n| 复盘 |") == [
            .table(.init(headers: ["工作", "状态", "数量"], alignments: [.left, .center, .right], rows: [["开发", "完成", "2"], ["复盘", "", ""]]))
        ])
    }
    @Test func tableKeepsEscapedPipesAndCodeSpans() {
        #expect(MarkdownBlocks.parse(#"| a\|b | `x|y` |"# + "\n| --- | --- |\n| ``a|`b`` | done |") == [
            .table(.init(headers: [#"a\|b"#, "`x|y`"], alignments: [.left, .left], rows: [["``a|`b``", "done"]]))
        ])
    }
    @Test func extraCellsFallBackWithoutLosingText() {
        let raw = "| A | B |\n| --- | --- |\n| one | two | extra |"
        #expect(MarkdownBlocks.parse(raw) == [.paragraph(raw)])
    }
    @Test func ordinaryPipesAndMalformedTablesStayLiteral() {
        for raw in ["one | two", "A | B\n-- | ---\n1 | 2", "A | B\n--- | --- | ---\n1 | 2"] {
            #expect(MarkdownBlocks.parse(raw) == [.paragraph(raw)])
        }
    }
    @Test func tablesDoNotParseInsideCodeFences() {
        let raw = "A | B\n--- | ---\n1 | 2"
        #expect(MarkdownBlocks.parse("```\n" + raw + "\n```") == [.code(raw)])
    }
    @Test func tableEndsBeforeFollowingParagraphAndHeading() {
        #expect(MarkdownBlocks.parse("A | B\n--- | ---\n1 | 2\n\n## 结论\n完成") == [
            .table(.init(headers: ["A", "B"], alignments: [.left, .left], rows: [["1", "2"]])), .heading(2, "结论"), .paragraph("完成")
        ])
    }
}
