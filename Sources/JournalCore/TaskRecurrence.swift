import Foundation

public enum TaskRecurrence: String, Codable, CaseIterable, Sendable {
    case none, daily, weekdays, weekly, monthly
    public var label: String {
        switch self {
        case .none: return "不重复"
        case .daily: return "每天"
        case .weekdays: return "工作日（周一至周五）"
        case .weekly: return "每周"
        case .monthly: return "每月"
        }
    }
}

public struct RecurrenceClock: Codable, Equatable, Sendable {
    public var hour: Int
    public var minute: Int
    public var second: Int
    public init(date: Date, calendar: Calendar = .current) {
        hour = calendar.component(.hour, from: date)
        minute = calendar.component(.minute, from: date)
        second = calendar.component(.second, from: date)
    }
}

public enum RecurringTasks {
    /// Keep the scheduled wall-clock time and skip missed periods without generating a backlog.
    public static func nextDeadline(for entry: Entry, after now: Date, calendar: Calendar = .current) throws -> Date {
        guard let due = entry.dueAt, entry.recurrence != .none else {
            throw JournalError.invalid("重复待办需要截止时间。")
        }
        let threshold = max(now, due)
        var candidate = due
        // Jump close to the threshold before advancing, including very old imported tasks.
        switch entry.recurrence {
        case .weekly:
            let days = calendar.dateComponents([.day], from: due, to: threshold).day ?? 0
            candidate = calendar.date(byAdding: .day, value: max(0, days / 7) * 7, to: due) ?? due
        case .monthly:
            let months = calendar.dateComponents([.month], from: due, to: threshold).month ?? 0
            candidate = calendar.date(byAdding: .month, value: max(0, months), to: due) ?? due
        default:
            let days = calendar.dateComponents([.day], from: due, to: threshold).day ?? 0
            candidate = calendar.date(byAdding: .day, value: max(0, days), to: due) ?? due
        }
        let anchor = entry.recurrenceDayOfMonth ?? calendar.component(.day, from: due)
        let clock = entry.recurrenceClock ?? RecurrenceClock(date: due, calendar: calendar)
        for _ in 0..<40 {
            // Rebuild each date from the saved wall clock; never inherit a skipped DST hour.
            var parts = calendar.dateComponents([.era, .year, .month, .day], from: candidate)
            if entry.recurrence == .monthly {
                parts.day = min(anchor, calendar.range(of: .day, in: .month, for: candidate)!.count)
            }
            parts.hour = clock.hour; parts.minute = clock.minute; parts.second = clock.second
            parts.nanosecond = calendar.component(.nanosecond, from: due)
            guard let adjusted = calendar.date(from: parts) else { break }
            candidate = adjusted
            if candidate > threshold && (entry.recurrence != .weekdays || ![1, 7].contains(calendar.component(.weekday, from: candidate))) {
                return candidate
            }
            let component: Calendar.Component = entry.recurrence == .monthly ? .month : .day
            let amount = entry.recurrence == .weekly ? 7 : 1
            guard let advanced = calendar.date(byAdding: component, value: amount, to: candidate) else { break }
            candidate = advanced
        }
        throw JournalError.invalid("无法计算下一次截止时间，请调整重复设置。")
    }
    public static func validate(_ entry: Entry) throws {
        if entry.recurrence != .none && entry.dueAt == nil {
            throw JournalError.invalid("重复待办需要设置截止时间。")
        }
        if let anchor = entry.recurrenceDayOfMonth, !(1...31).contains(anchor) {
            throw JournalError.invalid("重复日期无效。")
        }
        if let clock = entry.recurrenceClock,
           !(0...23).contains(clock.hour) || !(0...59).contains(clock.minute) || !(0...59).contains(clock.second) {
            throw JournalError.invalid("重复提醒时刻无效。")
        }
        for date in [entry.dueAt, entry.snoozedUntil].compactMap({ $0 }) {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw JournalError.invalid("提醒日期无效。") }
        }
    }
}

public enum SnoozeChoice: String, CaseIterable, Sendable {
    case halfHour, oneHour, tomorrow
    public var label: String {
        switch self {
        case .halfHour: return "30 分钟后"
        case .oneHour: return "1 小时后"
        case .tomorrow: return "明天 09:00"
        }
    }
    public func date(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .halfHour: return now.addingTimeInterval(1800)
        case .oneHour: return now.addingTimeInterval(3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        }
    }
}
