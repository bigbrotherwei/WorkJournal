import Foundation
import Testing
@testable import JournalCore

struct OCRIndexTests {
    private func fixture() -> (Entry, NoteDocument, NoteAsset) {
        var entry = Entry(text: "图片记录", day: "2026-11-18")
        entry.images = [ImageAttachment(name: "record.png", data: Data([1, 2, 3]))]
        var note = NoteDocument(title: "图片笔记")
        let asset = NoteAsset(ownerNoteID: note.id, fileName: "note.png", mimeType: "image/png", kind: .image, data: Data([4, 5, 6]))
        note.markdown = "![](\(asset.reference))"
        return (entry, note, asset)
    }

    @Test func validatesEachImageAndOwnerFingerprintBeforeSearching() throws {
        var (entry, note, asset) = fixture()
        let sources = try OCRSourceBuilder.sources(entries: [entry], notes: [note], assets: [asset])
        var index = OCRIndex()
        for source in sources { index.record(source: source, text: "合成图片文字") }
        let texts = index.validatedTexts(currentSources: sources)
        #expect(texts.count == 2)
        #expect(try UnifiedSearch.search(.init(text: "图片文字"), in: .init(entries: [entry], notes: [note], ocrTexts: texts)).count == 2)
        entry.text = "修改后的内容"
        note.title = "修改后的标题"
        #expect(try UnifiedSearch.search(.init(text: "图片文字"), in: .init(entries: [entry], notes: [note], ocrTexts: texts)).isEmpty)
        asset.data = Data([9])
        let replacement = try OCRSourceBuilder.sources(entries: [entry], notes: [note], assets: [asset])
        #expect(index.validatedTexts(currentSources: replacement).isEmpty)
        #expect(index.validatedTexts(currentSources: []).isEmpty)
    }

    @Test func removedReferencesTrashAndNonImagesDoNotProduceSources() throws {
        var (entry, note, asset) = fixture()
        entry.deletedAt = Date(); note.markdown = "图片已移除"
        #expect(try OCRSourceBuilder.sources(entries: [entry], notes: [note], assets: [asset]).isEmpty)
        note.markdown = "![](\(asset.reference))"; asset.kind = .pdf
        #expect(try OCRSourceBuilder.sources(notes: [note], assets: [asset]).isEmpty)
        asset.kind = .image
        var folder = NoteFolder(name: "已删除"); folder.deletedAt = Date(); note.folderID = folder.id
        #expect(try OCRSourceBuilder.sources(notes: [note], folders: [folder], assets: [asset]).isEmpty)
    }

    @Test func imageReplacementAloneInvalidatesCacheAndRemovedImageDoesNotMatch() throws {
        var (entry, note, asset) = fixture()
        let sources = try OCRSourceBuilder.sources(entries: [entry], notes: [note], assets: [asset])
        var index = OCRIndex(); for source in sources { index.record(source: source, text: "旧图专用文字") }
        entry.images[0].data = Data([8]); asset.data = Data([9])
        #expect(index.validatedTexts(currentSources: try OCRSourceBuilder.sources(entries: [entry], notes: [note], assets: [asset])).isEmpty)
        let oldTexts = index.validatedTexts(currentSources: sources)
        entry.images = []
        #expect(try UnifiedSearch.search(.init(text: "旧图专用文字"), in: .init(entries: [entry], ocrTexts: oldTexts)).isEmpty)
    }

    @Test func cacheRoundTripPrunesStaleSourcesAndRejectsCorruption() throws {
        let (entry, _, _) = fixture()
        let source = try #require(OCRSourceBuilder.sources(entries: [entry]).first)
        var index = OCRIndex(); index.record(source: source, text: "可检索")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OCRCacheStore(url: directory.appendingPathComponent("cache.json"))
        try cache.save(index)
        #expect(try cache.load().validatedTexts(currentSources: [source]).first?.text == "可检索")
        index.prune(currentSources: [])
        try cache.save(index)
        #expect(try cache.load().validatedTexts(currentSources: [source]).isEmpty)
        try Data("not a cache".utf8).write(to: cache.url)
        #expect(throws: (any Error).self) { try cache.load() }
    }

    @Test func batchContinuesAfterFailureAndCancellationStopsBeforeNextImage() throws {
        let (entry, note, asset) = fixture()
        let sources = try OCRSourceBuilder.sources(entries: [entry], notes: [note], assets: [asset])
        let output = try OCRBatchProcessor.process(sources: sources, index: OCRIndex(), recognize: { data in
            if data == Data([1, 2, 3]) { throw JournalError.invalid("损坏图片") }
            return "第二张成功"
        })
        #expect(output.errors.count == 1)
        #expect(output.index.validatedTexts(currentSources: sources).map(\.text) == ["第二张成功"])
        var processed = 0
        #expect(throws: CancellationError.self) {
            try OCRBatchProcessor.process(sources: sources, index: OCRIndex(), recognize: { _ in processed += 1; return "x" }, cancelled: { processed == 1 })
        }
        #expect(processed == 1)
    }
}

import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct LocalOCRVisionTests {
    // Vision needs access to macOS compute services blocked by the development sandbox.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKJOURNAL_TEST_VISION"] == "1"))
    func recognizesSyntheticRecordAndNoteImagesThenRejectsDeletedOwners() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vision-ocr-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("journal.sqlite")
        let store = try JournalStore(url: url)
        let image = try syntheticTextImage()
        var entry = Entry(text: "合成记录", day: "2026-11-18")
        entry.images = [ImageAttachment(name: "synthetic.png", data: image)]
        try store.save(entry)
        var note = try store.saveNote(NoteDocument(title: "合成笔记"))
        let asset = NoteAsset(ownerNoteID: note.id, fileName: "synthetic.png", mimeType: "image/png", kind: .image, data: image)
        try store.saveNoteAsset(asset)
        note.markdown = "![](\(asset.reference))"; note = try store.saveNote(note, expectedRevision: note.revision)
        let worker = LocalOCRWorker(databaseURL: url, cacheURL: directory.appendingPathComponent("ocr.json"))
        let result = try await worker.run()
        #expect(result.errors.isEmpty)
        #expect(result.recognized == 2)
        let texts = try await worker.validatedTexts()
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { $0.text.contains("SYNTHETIC") && $0.text.contains("2026") })
        let reused = try await worker.run()
        #expect(reused.recognized == 0 && reused.reused == 2)
        try store.delete(id: entry.id); try store.deleteNote(id: note.id)
        #expect(try await worker.validatedTexts().isEmpty)
    }

    private func syntheticTextImage() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 1_000, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 180))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SYNTHETIC OCR 2026", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        context.textPosition = CGPoint(x: 30, y: 65); CTLineDraw(line, context)
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
