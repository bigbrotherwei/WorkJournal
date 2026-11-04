import Foundation

public enum FollowUp: String, Codable, CaseIterable, Sendable {
    case none = "无状态", pending = "待处理", done = "已完成"
}
public struct Entry: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var text: String
    public var day: String
    public var createdAt = Date()
    public var updatedAt = Date()
    public var inReport = false
    public var status: FollowUp = .none
    public var category = "未分类"
    public var manualCategory = false
    public var dueAt: Date?
    public var reminderEnabled = false
    public var recurrence: TaskRecurrence = .none
    public var recurrenceDayOfMonth: Int?
    public var recurrenceClock: RecurrenceClock?
    public var recurrenceSeriesID: UUID?
    public var snoozedUntil: Date?
    public var nextOccurrenceID: UUID?
    public var deletedAt: Date?
    public var images: [ImageAttachment] = []
    public var plainText: String { RecordContent.plainText(text) }
    public var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }
    private enum CodingKeys: String, CodingKey {
        case id, text, day, createdAt, updatedAt, inReport, status, category, manualCategory, images, dueAt, reminderEnabled, deletedAt
        case recurrence, recurrenceDayOfMonth, recurrenceClock, recurrenceSeriesID, snoozedUntil, nextOccurrenceID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text); day = try c.decode(String.self, forKey: .day)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        inReport = try c.decode(Bool.self, forKey: .inReport); status = try c.decode(FollowUp.self, forKey: .status)
        category = try c.decode(String.self, forKey: .category); manualCategory = try c.decode(Bool.self, forKey: .manualCategory)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        reminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? false
        recurrence = try c.decodeIfPresent(TaskRecurrence.self, forKey: .recurrence) ?? .none
        recurrenceDayOfMonth = try c.decodeIfPresent(Int.self, forKey: .recurrenceDayOfMonth)
        recurrenceClock = try c.decodeIfPresent(RecurrenceClock.self, forKey: .recurrenceClock)
        recurrenceSeriesID = try c.decodeIfPresent(UUID.self, forKey: .recurrenceSeriesID)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        nextOccurrenceID = try c.decodeIfPresent(UUID.self, forKey: .nextOccurrenceID)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        images = try c.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
    }
    public init(text: String, day: String) { self.text = text; self.day = day }
}
public struct Report: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var day: String
    public var text: String
    public var createdAt = Date()
    public var sourceFingerprint: String?
    public init(day: String, text: String, sourceFingerprint: String? = nil) {
        self.day = day; self.text = text; self.sourceFingerprint = sourceFingerprint
    }
}
public enum JournalError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}
public enum Days {
    public static func key(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
