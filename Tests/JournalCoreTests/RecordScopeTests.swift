import Testing
@testable import JournalCore
struct RecordScopeTests {
    @Test func scopesUseAssignedDayAndPendingIncludesOlderItems() {
        var old = Entry(text: "补记", day: "2026-11-02"); old.status = .pending; old.inReport = true
        var today = Entry(text: "今日", day: "2026-11-03"); today.inReport = true
        let note = Entry(text: "灵感", day: "2026-11-03")
        let entries = [old, today, note]
        #expect(entries.filter { RecordScope.today.includes($0, today: "2026-11-03") }.map(\.id) == [today.id, note.id])
        #expect(entries.filter { RecordScope.pending.includes($0, today: "2026-11-03") }.map(\.id) == [old.id])
        #expect(entries.filter { RecordScope.report.includes($0, today: "2026-11-03") }.map(\.id) == [today.id])
        #expect(entries.filter { RecordScope.all.includes($0, today: "2026-11-03") }.count == 3)
    }
}
