import Foundation

public enum RecordScope: String, CaseIterable, Sendable {
    case all = "全部记录", today = "今日记录", pending = "待处理事项", report = "今日日报素材"
    public func includes(_ entry: Entry, today: String) -> Bool {
        switch self {
        case .all: return true
        case .today: return entry.day == today
        case .pending: return entry.status == .pending
        case .report: return entry.day == today && entry.inReport
        }
    }
    public var icon: String {
        switch self {
        case .all: return "tray.full"
        case .today: return "square.and.pencil"
        case .pending: return "circle.dashed"
        case .report: return "doc.text"
        }
    }
}
