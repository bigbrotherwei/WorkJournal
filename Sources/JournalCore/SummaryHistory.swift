import Foundation

public struct SummaryHistoryItem: Identifiable, Sendable {
    public let id: String
    public let summary: RangeSummary
    public let isDraft: Bool

    public static func build(saved: [RangeSummary], drafts: [String: RangeSummary]) -> [SummaryHistoryItem] {
        var rows = saved.map { SummaryHistoryItem(id: "saved_\($0.id)", summary: $0, isDraft: false) }
        for (key, draft) in drafts where !key.hasPrefix("recovery_") && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A loaded saved version is also cached as a draft. Only show it twice
            // when its contents or source selection have actually changed.
            let alreadySaved = saved.contains {
                $0.startDay == draft.startDay && $0.endDay == draft.endDay &&
                $0.includeAllRecords == draft.includeAllRecords && $0.text == draft.text &&
                $0.sourceFingerprint == draft.sourceFingerprint
            }
            if !alreadySaved { rows.append(SummaryHistoryItem(id: "draft_\(key)", summary: draft, isDraft: true)) }
        }
        return rows.sorted {
            if $0.summary.startDay != $1.summary.startDay { return $0.summary.startDay > $1.summary.startDay }
            if $0.summary.endDay != $1.summary.endDay { return $0.summary.endDay > $1.summary.endDay }
            if $0.isDraft != $1.isDraft { return $0.isDraft }
            if $0.summary.createdAt != $1.summary.createdAt { return $0.summary.createdAt > $1.summary.createdAt }
            return $0.id > $1.id
        }
    }
}
