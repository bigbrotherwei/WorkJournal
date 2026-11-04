import Foundation

public struct ReportArchiveDay: Identifiable, Sendable {
    public enum State: String, Sendable {
        case unsaved = "尚未保存日报", current = "已归档", changed = "素材已变化", unverified = "素材待核对"
    }
    public var id: String { day }
    public let day: String
    public let sourceCount: Int
    public let versionCount: Int
    public let latestReport: Report?
    public let state: State

    public static func build(entries: [Entry], reports: [Report]) -> [ReportArchiveDay] {
        let sources = Dictionary(grouping: entries.filter(\.inReport), by: \.day)
        let versions = Dictionary(grouping: reports, by: \.day)
        return Set(sources.keys).union(versions.keys).sorted(by: >).map { day in
            let items = versions[day] ?? []
            let latest = items.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt
            }.first
            let state: State
            if let latest {
                if let fingerprint = latest.sourceFingerprint {
                    state = fingerprint == ReportFreshness.fingerprint(day: day, entries: sources[day] ?? []) ? .current : .changed
                } else { state = .unverified }
            } else { state = .unsaved }
            return ReportArchiveDay(day: day, sourceCount: sources[day]?.count ?? 0,
                                    versionCount: items.count, latestReport: latest, state: state)
        }
    }
}
