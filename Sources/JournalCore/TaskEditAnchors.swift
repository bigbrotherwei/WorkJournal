import Foundation

/// Keep an actively edited task in its original section until its editor closes.
public struct TaskEditAnchors {
    private var groups: [UUID: TaskDueGroup] = [:]
    public init() {}
    public mutating func begin(_ entry: Entry, now: Date = Date()) {
        if groups[entry.id] == nil { groups[entry.id] = ReminderPolicy.group(for: entry, now: now) }
    }
    public mutating func end(_ id: UUID) { groups.removeValue(forKey: id) }
    public func group(for entry: Entry, now: Date) -> TaskDueGroup {
        groups[entry.id] ?? ReminderPolicy.group(for: entry, now: now)
    }
}
