import Foundation

import Testing
@testable import JournalCore

struct RecordContentTests {
    @Test func testInlineOrderAndModelText() throws {
        let id = UUID()
        let text = "修复之前\n" + RecordContent.marker(id) + "\n修复之后"
        #expect(RecordContent.parts(text) == [.text("修复之前\n"), .image(id), .text("\n修复之后")])
        #expect(Entry(text: text, day: "2026-11-04").plainText == "修复之前\n\n\n修复之后")
    }
    @Test func testAtomicDraftRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("draft.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DraftImageStore(url: url)
        #expect(try store.load() == nil)
        let draft = RecordDraft(text: "保留文字和顺序")
        try store.save(draft)
        #expect(try store.load() == draft)
    }
    @Test func imageOnlyCannotGenerateReport() throws {
        var entry = Entry(text: "\n" + RecordContent.marker(UUID()) + "\n", day: "2026-11-04")
        entry.inReport = true
        #expect(throws: (any Error).self) { try ReportBatchPlanner.batches(day: entry.day, entries: [entry]) }
        #expect(throws: (any Error).self) { try Prompts.report(day: entry.day, entries: [entry]) }
    }
    @Test func inlineImageRoundTripAndMissingImage() throws {
        let image = ImageAttachmentTests().picture()
        let content = RecordDraft(text: "前\n" + RecordContent.marker(image.id) + "\n后", images: [image])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("draft.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DraftImageStore(url: url)
        try store.save(content)
        #expect(try store.load() == content)
        #expect(throws: (any Error).self) { try store.save(RecordDraft(text: content.text)) }
        #expect(try store.load() == content)
    }
}
