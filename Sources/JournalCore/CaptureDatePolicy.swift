import Foundation

public enum CaptureDatePolicy {
    private static func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public static func onOpen(text: String, selected: Date, manual: Bool, now: Date) -> Date {
        !manual && blank(text) ? now : selected
    }
    public static func onInput(previous: String, text: String, selected: Date, manual: Bool, now: Date) -> Date {
        !manual && blank(previous) && !blank(text) ? now : selected
    }
}
