import Foundation

/// Applied locally after synthesis. Fixed text is never sent to the model.
public struct ReportTemplate: Sendable {
    public var opening: String
    public var closing: String
    public init(opening: String = "", closing: String = "") {
        self.opening = opening; self.closing = closing
    }
    public func render(day: String, body: String) -> String {
        let dated = ReportDocument.dated(day: day, text: body)
        guard !opening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
              !closing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return dated }
        let heading = "# \(day)"
        let content = String(dated.dropFirst(heading.count).drop(while: { $0.isNewline }))
        return [heading, opening, content, closing]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}
