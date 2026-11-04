import Foundation

public enum ReportMarkdownExport {
    /// Archive rows already apply the same latest-version tie breaker as the editor.
    public static func render(rows: [ReportArchiveDay], selectedDays: Set<String>) -> String {
        let sections = rows.sorted { $0.day < $1.day }.compactMap { row -> String? in
            guard selectedDays.contains(row.day), let report = row.latestReport else { return nil }
            return ReportDocument.dated(day: row.day, text: report.text)
        }
        return sections.isEmpty ? "" : sections.joined(separator: "\n\n---\n\n") + "\n"
    }
}
