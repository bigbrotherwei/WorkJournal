import Foundation
import Testing
@testable import JournalCore

struct TaskEditAnchorsTests {
    @Test func openEditorSurvivesDeadlineCrossingAndRegroupsAfterClosing() {
        let now = Date(timeIntervalSince1970: 1_799_999_000)
        var entry = Entry(text: "Pending work", day: Days.key(now))
        entry.status = .pending; entry.dueAt = now.addingTimeInterval(20)
        var anchors = TaskEditAnchors()
        let initialGroup = anchors.group(for: entry, now: now)
        anchors.begin(entry, now: now)
        let later = now.addingTimeInterval(60)
        #expect(ReminderPolicy.group(for: entry, now: later) == .overdue)
        #expect(anchors.group(for: entry, now: later) == initialGroup)
        // Opening a nested content editor must not change the original anchor.
        anchors.begin(entry, now: later)
        #expect(anchors.group(for: entry, now: later) == initialGroup)
        anchors.end(entry.id)
        #expect(anchors.group(for: entry, now: later) == .overdue)
    }
    @Test func savedDeadlineDoesNotMovePresentationOwnerUntilEditingEnds() {
        let now = Date()
        var entry = Entry(text: "Arrange work", day: Days.key(now)); entry.status = .pending
        var anchors = TaskEditAnchors(); anchors.begin(entry, now: now)
        let initialGroup = anchors.group(for: entry, now: now)
        entry.dueAt = now.addingTimeInterval(-120)
        #expect(anchors.group(for: entry, now: now) == initialGroup)
        anchors.end(entry.id)
        #expect(anchors.group(for: entry, now: now) == .overdue)
    }
}
