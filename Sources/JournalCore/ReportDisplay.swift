import Foundation

public enum ReportDisplay {
    public static func content(saved: Report?, draft: ReportDraft?) -> ReportDraft {
        if let draft, !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return draft }
        return ReportDraft(text: saved?.text ?? "", sourceFingerprint: saved?.sourceFingerprint)
    }
}
