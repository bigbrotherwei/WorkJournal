import Foundation
import Testing
@testable import JournalCore

struct EntryEditingTests {
    @Test func textEditPreservesBackgroundCategoryAndManualFlag() throws {
        let original = Entry(text: "排查超时", day: "2026-10-30")
        var edited = original; edited.text = "排查超时，原因未确认"
        var current = original; current.category = "接口服务"
        let merged = try EntryEditing.merge(original: original, edited: edited, current: current)
        #expect(merged.text == edited.text)
        #expect(merged.category == "接口服务" && !merged.manualCategory)
        current.manualCategory = true
        #expect(try EntryEditing.merge(original: original, edited: edited, current: current).manualCategory)
    }
    @Test func explicitCategoryWinsAndUnclassifiedReleasesManualOverride() throws {
        var original = Entry(text: "排查", day: "2026-10-30"); original.category = "接口"
        var edited = original; edited.category = "  网关  "
        var current = original; current.category = "后台新类别"
        let manual = try EntryEditing.merge(original: original, edited: edited, current: current)
        #expect(manual.category == "网关" && manual.manualCategory)
        edited.category = "  "
        let reset = try EntryEditing.merge(original: manual, edited: edited, current: manual)
        #expect(reset.category == "未分类" && !reset.manualCategory)
    }
    @Test func onlyChangedFieldsOverwriteLatestValues() throws {
        var original = Entry(text: "旧内容", day: "2026-10-29"); original.inReport = true
        var edited = original; edited.status = .done
        var current = original; current.text = "另一次保存的内容"; current.day = "2026-10-28"
        let now = Date(timeIntervalSince1970: 100)
        let merged = try EntryEditing.merge(original: original, edited: edited, current: current, now: now)
        #expect(merged.text == current.text && merged.day == current.day && merged.inReport)
        #expect(merged.status == .done && merged.updatedAt == now)
        #expect(merged.id == original.id && merged.createdAt == original.createdAt)
    }
    @Test func cannotMergeDifferentRecords() {
        let original = Entry(text: "a", day: "2026-10-30")
        let other = Entry(text: "b", day: "2026-10-30")
        #expect(throws: (any Error).self) { try EntryEditing.merge(original: original, edited: original, current: other) }
    }
}
