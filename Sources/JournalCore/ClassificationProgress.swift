import Foundation

/// Attempts are remembered for the exact entry snapshot: "未分类" responses and
/// failures do not loop forever, while edits and newly saved records remain eligible.
public struct ClassificationProgress {
    private var attempted: [UUID: Entry] = [:]
    public init() {}
    public mutating func markAttempted(_ entry: Entry) { attempted[entry.id] = entry }
    public mutating func reset() { attempted.removeAll() }
    public func next(in entries: [Entry]) -> Entry? {
        entries.filter { $0.deletedAt == nil && !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.category == "未分类" && !$0.manualCategory && attempted[$0.id] != $0 }
            .min { $0.createdAt < $1.createdAt }
    }
}

public enum NextWork: Equatable { case report, manualClassification, backgroundClassification, idle }
public enum ContinuationPolicy {
    public static func next(reportWaiting: Bool, manualRequested: Bool, paused: Bool, powerSaving: Bool, hasCandidates: Bool) -> NextWork {
        if reportWaiting { return .report }
        guard !paused && hasCandidates else { return .idle }
        if manualRequested { return .manualClassification }
        return powerSaving ? .idle : .backgroundClassification
    }
}
