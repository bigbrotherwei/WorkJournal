import Foundation

public struct RecordActivity: Sendable {
    public struct Day: Identifiable, Sendable {
        public let day: String
        public let count: Int
        public let isFuture: Bool
        public var id: String { day }
    }
    public let days: [Day]
    public var total: Int { days.reduce(0) { $0 + $1.count } }
    public var activeDays: Int { days.filter { $0.count > 0 }.count }
    public init(entries: [Entry], now: Date = Date(), timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -mondayOffset - 77, to: today)!
        let counts = Dictionary(grouping: entries, by: \.day).mapValues(\.count)
        days = (0..<84).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let day = Days.key(date, timeZone: timeZone)
            return Day(day: day, count: date > today ? 0 : counts[day, default: 0], isFuture: date > today)
        }
    }
    public static func level(_ count: Int) -> Int {
        switch count {
        case ...0: return 0
        case 1: return 1
        case 2...3: return 2
        case 4...5: return 3
        default: return 4
        }
    }
}
