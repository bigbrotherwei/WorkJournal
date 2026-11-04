import Foundation
import Testing
@testable import JournalCore

struct IterationThreeTests {
    @Test func reportFingerprintTracksOnlyRelevantMaterialAndIgnoresOrder() {
        var entry = Entry(text: "排查中", day: "2026-10-30"); entry.inReport = true
        var second = entry; second.id = UUID(); second.text = "Review 完成"
        let baseline = ReportFreshness.fingerprint(day: entry.day, entries: [entry, second])
        #expect(baseline == ReportFreshness.fingerprint(day: entry.day, entries: [second, entry]))
        var changed = entry; changed.text = "已经修复"
        #expect(baseline != ReportFreshness.fingerprint(day: entry.day, entries: [changed, second]))
        #expect(baseline != ReportFreshness.fingerprint(day: entry.day, entries: [second]))
        changed = entry; changed.inReport = false
        #expect(baseline != ReportFreshness.fingerprint(day: entry.day, entries: [changed, second]))
        changed = entry; changed.updatedAt = Date().addingTimeInterval(60)
        #expect(baseline == ReportFreshness.fingerprint(day: entry.day, entries: [changed, second]))
        let thought = Entry(text: "无关思路", day: entry.day)
        #expect(baseline == ReportFreshness.fingerprint(day: entry.day, entries: [thought, entry, second]))
    }
    @Test func shortcutRejectsUnsafeOrUnknownBindings() throws {
        #expect(throws: (any Error).self) { try ShortcutConfiguration(control: false, option: false).validate() }
        #expect(throws: (any Error).self) { try ShortcutConfiguration(control: false, option: false, command: true).validate() }
        #expect(throws: (any Error).self) { try ShortcutConfiguration(keyCode: 999).validate() }
        try ShortcutConfiguration().validate()
    }
    @Test func failedShortcutRegistrationKeepsPreviousSelection() throws {
        let original = ShortcutConfiguration()
        let replacement = ShortcutConfiguration(keyCode: 0)
        var selection = ShortcutSelection(current: original)
        #expect(throws: (any Error).self) {
            try selection.apply(replacement) { _ in throw JournalError.invalid("快捷键冲突") }
        }
        #expect(selection.current == original)
        try selection.apply(replacement) { _ in }
        #expect(selection.current == replacement)
    }
    @Test func legacyReportsDecodeAndFingerprintSurvivesBackupRoundTrip() throws {
        let original = Report(day: "2026-10-30", text: "旧日报")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "sourceFingerprint")
        let decoded = try JSONDecoder().decode(Report.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.sourceFingerprint == nil)
        #expect(decoded.text == original.text)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fingerprints-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("source.sqlite"))
        let destination = try JournalStore(url: root.appendingPathComponent("target.sqlite"))
        let report = Report(day: original.day, text: "手工修改后的日报", sourceFingerprint: "original-baseline")
        try store.saveReport(report)
        _ = try destination.importBackup(store.exportBackup())
        #expect(try destination.reports(day: report.day) == [report])
        let draft = ReportDraft(text: report.text, sourceFingerprint: report.sourceFingerprint)
        let restored = try JSONDecoder().decode(ReportDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored.sourceFingerprint == "original-baseline")
    }
    @Test func categoryAndFollowupChangesInvalidateReportFingerprint() {
        var entry = Entry(text: "处理问题", day: "2026-10-30"); entry.inReport = true
        let baseline = ReportFreshness.fingerprint(day: entry.day, entries: [entry])
        entry.status = .done
        #expect(baseline != ReportFreshness.fingerprint(day: entry.day, entries: [entry]))
        entry.status = .none; entry.category = "登录模块"
        #expect(baseline != ReportFreshness.fingerprint(day: entry.day, entries: [entry]))
    }
}
