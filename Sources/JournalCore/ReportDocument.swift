import Foundation

public enum ReportDocument {
    /// The selected report day is authoritative; the model only supplies the body.
    public static func dated(day: String, text: String) -> String {
        let heading = "# \(day)"
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        if firstLine == heading { return text }
        if firstLine == "# 日报 · \(day)" {
            return heading + text.dropFirst(firstLine.count)
        }
        return heading + "\n\n" + text
    }
}
