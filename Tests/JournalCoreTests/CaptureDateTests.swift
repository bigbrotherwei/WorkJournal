import Foundation
import Testing
@testable import JournalCore

struct CaptureDateTests {
    let yesterday = Date(timeIntervalSince1970: 1000)
    let today = Date(timeIntervalSince1970: 1000 + 86400)
    @Test func emptyWindowUsesDateOfFirstRealInput() {
        #expect(CaptureDatePolicy.onInput(previous: " \n", text: "排查超时", selected: yesterday, manual: false, now: today) == today)
        #expect(CaptureDatePolicy.onInput(previous: "", text: "  ", selected: yesterday, manual: false, now: today) == yesterday)
    }
    @Test func existingDraftKeepsOriginalDateAcrossMidnightAndReopen() {
        #expect(CaptureDatePolicy.onInput(previous: "已有草稿", text: "已有草稿继续", selected: yesterday, manual: false, now: today) == yesterday)
        #expect(CaptureDatePolicy.onOpen(text: "已有草稿", selected: yesterday, manual: false, now: today) == yesterday)
    }
    @Test func manualBackfillSurvivesEmptyReopenAndTyping() {
        #expect(CaptureDatePolicy.onOpen(text: "", selected: yesterday, manual: true, now: today) == yesterday)
        #expect(CaptureDatePolicy.onInput(previous: "", text: "补记", selected: yesterday, manual: true, now: today) == yesterday)
    }
    @Test func clearedAutomaticDraftStartsOnCurrentDay() {
        #expect(CaptureDatePolicy.onOpen(text: " \n", selected: yesterday, manual: false, now: today) == today)
        #expect(CaptureDatePolicy.onInput(previous: "", text: "新记录", selected: yesterday, manual: false, now: today) == today)
    }
}
