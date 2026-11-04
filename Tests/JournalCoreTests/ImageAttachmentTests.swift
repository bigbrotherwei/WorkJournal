import Foundation
import Testing
@testable import JournalCore

struct ImageAttachmentTests {
    func picture() -> ImageAttachment {
        ImageAttachment(name: "示例.png", data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1cAAAAASUVORK5CYII=")!)
    }
    @Test func legacyEntriesDecodeWithoutImages() throws {
        let entry = Entry(text: "旧记录", day: "2026-11-04")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object.removeValue(forKey: "images")
        let restored = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.images.isEmpty && restored.text == entry.text)
    }
    @Test func imageOnlyRecordSurvivesSaveBackupRestoreAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("source.sqlite"))
        var entry = Entry(text: "", day: "2026-11-04"); entry.images = [picture()]
        try store.save(entry)
        #expect(try store.entries() == [entry])
        let backup = try store.exportBackup()
        let other = try JournalStore(url: root.appendingPathComponent("target.sqlite"))
        _ = try other.importBackup(backup)
        #expect(try other.entries() == [entry])
        try store.delete(id: entry.id); try store.save(entry)
        #expect(try store.entries().first?.images.first?.data == entry.images[0].data)
        #expect(ClassificationProgress().next(in: [entry]) == nil)
    }
    @Test func corruptOrOversizedAttachmentsAreRejectedAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JournalStore(url: root.appendingPathComponent("journal.sqlite"))
        var entry = Entry(text: "保留", day: "2026-11-04"); try store.save(entry)
        entry.images = [ImageAttachment(name: "bad.png", data: Data("not an image".utf8))]
        #expect(throws: (any Error).self) { try store.save(entry) }
        entry.images = (0..<5).map { _ in picture() }
        #expect(throws: (any Error).self) { try store.save(entry) }
        entry.images = [ImageAttachment(name: "huge.png", data: Data(count: 2_000_001))]
        #expect(throws: (any Error).self) { try store.save(entry) }
        #expect(try store.entries().first?.images.isEmpty == true)
    }
    @Test func imageEditsMergeWithoutLosingConcurrentMetadata() throws {
        var original = Entry(text: "图文", day: "2026-11-04"); original.images = [picture()]
        var edited = original; edited.images = []
        var current = original; current.category = "后台分类"
        let merged = try EntryEditing.merge(original: original, edited: edited, current: current)
        #expect(merged.images.isEmpty && merged.category == "后台分类")
    }
}
