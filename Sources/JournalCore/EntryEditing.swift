import Foundation

public enum EntryEditing {
    /// Apply only fields the user changed, preserving newer background classification.
    public static func merge(original: Entry, edited: Entry, current: Entry, now: Date = Date()) throws -> Entry {
        guard original.id == edited.id, original.id == current.id else {
            throw JournalError.invalid("记录不匹配，请关闭编辑窗口后重试。")
        }
        var result = current
        if edited.text != original.text { result.text = edited.text }
        if edited.images != original.images { result.images = edited.images }
        if edited.dueAt != original.dueAt { result.dueAt = edited.dueAt }
        if edited.reminderEnabled != original.reminderEnabled { result.reminderEnabled = edited.reminderEnabled }
        if edited.day != original.day { result.day = edited.day }
        if edited.inReport != original.inReport { result.inReport = edited.inReport }
        if edited.status != original.status { result.status = edited.status }
        func normalized(_ category: String) -> String {
            let value = category.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "未分类" : value
        }
        let category = normalized(edited.category)
        if category != normalized(original.category) {
            result.category = category
            result.manualCategory = category != "未分类"
        }
        result.updatedAt = now
        return result
    }
}
