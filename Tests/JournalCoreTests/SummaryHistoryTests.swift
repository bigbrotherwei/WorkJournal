import Foundation
import Testing
@testable import JournalCore

struct SummaryHistoryTests {
    private func summary(_ start: String, _ end: String, _ text: String, time: Double = 1, all: Bool = false) -> RangeSummary {
        var value = RangeSummary(startDay: start, endDay: end, text: text, sourceFingerprint: "source", includeAllRecords: all)
        value.createdAt = Date(timeIntervalSince1970: time)
        return value
    }

    @Test func storageReturnsAllRangesScopesAndVersionsAfterReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        let old = summary("2026-10-26", "2026-11-01", "旧周报")
        let revised = summary(old.startDay, old.endDay, "修改版", time: 3)
        let all = summary(old.startDay, old.endDay, "全部记录", time: 2, all: true)
        let custom = summary("2026-10-01", "2026-10-15", "自选范围", time: 4)
        do {
            let store = try JournalStore(url: url)
            #expect(try store.allSummaries().isEmpty)
            for value in [all, custom, revised, old] { try store.saveSummary(value) }
        }
        let reopened = try JournalStore(url: url)
        #expect(try reopened.allSummaries().map(\.id) == [custom, revised, all, old].map(\.id))
        #expect(try reopened.summaries(startDay: old.startDay, endDay: old.endDay).count == 3)
    }

    @Test func historyKeepsEveryVersionAndOrdersByRangeThenTime() {
        let old = summary("2026-10-26", "2026-11-01", "旧版", time: 10)
        let revised = summary(old.startDay, old.endDay, "新版", time: 20)
        let current = summary("2026-11-02", "2026-11-08", "本周", time: 1)
        let rows = SummaryHistoryItem.build(saved: [revised, current, old], drafts: [:])
        #expect(rows.map(\.summary.id) == [current, revised, old].map(\.id))
        #expect(rows.allSatisfy { !$0.isDraft })
        #expect(SummaryHistoryItem.build(saved: [], drafts: [:]).isEmpty)
    }

    @Test func unchangedDraftIsNotDuplicatedButEditedDraftIsPreserved() {
        let saved = summary("2026-10-26", "2026-11-01", "已保存")
        let key = "2026-10-26_2026-11-01_false"
        #expect(SummaryHistoryItem.build(saved: [saved], drafts: [key: saved]).count == 1)
        var edited = saved; edited.text = "未保存的修改"
        let rows = SummaryHistoryItem.build(saved: [saved], drafts: [key: edited])
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.first?.isDraft == true)
        #expect(rows.first?.summary.text == edited.text)
    }

    @Test func draftOnlyHistoryExcludesEmptyAndRecoverySlotsAndKeepsDifferentScope() {
        let saved = summary("2026-10-26", "2026-11-01", "相同文字")
        let all = summary(saved.startDay, saved.endDay, saved.text, all: true)
        let blank = summary("2026-11-02", "2026-11-08", " \n\t")
        let older = summary("2026-10-01", "2026-10-15", "仅草稿")
        let rows = SummaryHistoryItem.build(saved: [saved], drafts: ["all": all, "blank": blank, "older": older, "recovery_test": saved])
        #expect(rows.count == 3)
        #expect(rows.filter(\.isDraft).map(\.summary.id) == [all, older].map(\.id))
    }

    @Test func tiedVersionsHaveStableOrder() {
        var first = summary("2026-10-26", "2026-11-01", "第一份")
        var second = first; second.text = "第二份"
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(SummaryHistoryItem.build(saved: [first, second], drafts: [:]).map(\.summary.id) == [second.id, first.id])
    }
}
