import Foundation

public enum TaskDueGroup: String, CaseIterable, Sendable {
    case overdue = "已逾期", today = "今天", future = "以后", noDate = "未设截止时间"
}

public enum ReminderPolicy {
    public static let identifierPrefix = "workjournal.followup."
    public static func identifier(for id: UUID) -> String { identifierPrefix + id.uuidString }
    public static func isActive(_ entry: Entry) -> Bool {
        entry.deletedAt == nil && entry.status == .pending && entry.reminderEnabled && entry.dueAt != nil
    }
    public static func notificationBody(for entry: Entry) -> String { String(entry.plainText.prefix(160)) }
    public static func matchesPending(_ entry: Entry, dueTimestamp: TimeInterval?, body: String) -> Bool {
        isActive(entry) && entry.dueAt?.timeIntervalSince1970 == dueTimestamp && notificationBody(for: entry) == body
    }
    public static func shouldSchedule(_ entry: Entry, now: Date = Date()) -> Bool {
        isActive(entry) && entry.dueAt! > now
    }
    public static func group(for entry: Entry, now: Date = Date(), calendar: Calendar = .current) -> TaskDueGroup {
        guard let due = entry.dueAt else { return .noDate }
        if due < now { return .overdue }
        return calendar.isDate(due, inSameDayAs: now) ? .today : .future
    }
    public static func pending(in entries: [Entry]) -> [Entry] {
        entries.filter { $0.deletedAt == nil && $0.status == .pending }.sorted {
            if $0.dueAt == $1.dueAt { return $0.createdAt < $1.createdAt }
            return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
        }
    }
}
