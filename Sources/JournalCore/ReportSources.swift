import Foundation

/// The text actually sent to the model, preserved independently of later edits/deletion.
public struct ReportSourceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let day: String
    public let text: String
    public let category: String
    public let status: String
    public init(_ entry: Entry) {
        id = entry.id; day = entry.day; text = entry.plainText; category = entry.category; status = entry.status.rawValue
    }
}
public struct ReportSourceCitation: Codable, Equatable, Sendable {
    public let point: String
    public let sourceIDs: [UUID]
}
public struct ReportProvenance: Codable, Equatable, Sendable {
    public let generatedText: String
    public let sources: [ReportSourceSnapshot]
    public let citations: [ReportSourceCitation]
    public static let promptRule = """
    来源追溯：每个“- 要点”行末附上 [[source:源UUID,源UUID]]，UUID 只能取自输入 sourceID 或 id；合并摘要时保留并合并原有来源标记。引用仅指支持这一要点的记录，不得猜测 UUID，不得把无关记录全选。标记由程序隐藏；正文仍只写简洁结论。没有可靠来源则省略标记。
    """
    public func sources(forPoint point: String, currentText: String) -> [ReportSourceSnapshot] {
        guard currentText == generatedText else { return [] }
        let matches = citations.filter { $0.point == point }
        // Repeated identical points are ambiguous after Markdown block parsing.
        guard matches.count == 1, let citation = matches.first else { return [] }
        // Fixed template bullets were never model input. An identical rendered point is ambiguous.
        let renderedMatches = MarkdownBlocks.parse(generatedText).filter {
            if case let .item(_, text) = $0 { return text == point }; return false
        }
        guard renderedMatches.count == 1 else { return [] }
        let allowed = Set(citation.sourceIDs)
        return sources.filter { allowed.contains($0.id) }
    }
    public static func build(body: String, entries: [Entry], day: String, template: ReportTemplate) -> (text: String, provenance: ReportProvenance) {
        var seen = Set<UUID>()
        let sources = entries.filter { $0.deletedAt == nil && !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted }.map(ReportSourceSnapshot.init)
        let allowed = Set(sources.map(\.id))
        let pattern = try! NSRegularExpression(pattern: #"\[\[source:([^\]\n]*)\]\]"#, options: .caseInsensitive)
        var citations: [ReportSourceCitation] = []
        let lines = body.components(separatedBy: "\n").map { line -> String in
            let range = NSRange(line.startIndex..., in: line)
            let matches = pattern.matches(in: line, range: range)
            var ids: [UUID] = []
            for match in matches {
                guard let capture = Range(match.range(at: 1), in: line) else { continue }
                for token in line[capture].split(separator: ",") {
                    if let id = UUID(uuidString: token.trimmingCharacters(in: .whitespacesAndNewlines)), allowed.contains(id), !ids.contains(id) { ids.append(id) }
                }
            }
            let clean = pattern.stringByReplacingMatches(in: line, range: range, withTemplate: "").replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            let trimmed = clean.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                citations.append(ReportSourceCitation(point: String(trimmed.dropFirst(2)), sourceIDs: ids))
            }
            return clean
        }
        let text = template.render(day: day, body: lines.joined(separator: "\n"))
        return (text, ReportProvenance(generatedText: text, sources: sources, citations: citations))
    }
}
