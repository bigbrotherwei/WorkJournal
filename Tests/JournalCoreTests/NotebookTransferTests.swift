import Testing
import Foundation
import AppKit
import PDFKit
import CryptoKit
import CoreText
@testable import JournalCore

struct NotebookTransferTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookTransfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func put(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    @Test func associatesYoudaoResourcesAndPreservesDirectories() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("before ![image](Sample.note.attach/image.png) after", "Folder/Sample.md", in: root)
        try put("synthetic image bytes", "Folder/Sample.note.attach/image.png", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        #expect(plan.snapshot.notes.count == 1)
        #expect(plan.snapshot.folders.map(\.name) == ["Folder"])
        #expect(plan.snapshot.assets.count == 1)
        #expect(plan.snapshot.notes[0].markdown.contains(plan.snapshot.assets[0].reference))
        #expect(plan.snapshot.assets[0].data == Data("synthetic image bytes".utf8))
        #expect(plan.snapshot.notes[0].sourceFingerprint != nil)
    }
    @Test func refusesTraversalSymlinksAndReportsOrphans() throws {
        let root = try fixture(); let outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try put("outside secret", "secret.png", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        try put("![bad](link.png) ![traversal](../secret.png)", "note.md", in: root)
        try put("orphan", "lost.note.attach/orphan.png", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        #expect(!plan.snapshot.assets.contains { $0.data == Data("outside secret".utf8) })
        #expect(plan.issues.count >= 3)
        #expect(plan.issues.contains { $0.severity == .error })
        #expect(plan.snapshot.assets.contains { $0.data == Data("orphan".utf8) })
        #expect(!plan.snapshot.folders.contains { $0.name.hasSuffix(".attach") })
    }
    @Test func enexRestoresInlineMediaTasksTagsAndTimes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("image bytes".utf8)
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try put("""
        <?xml version="1.0"?><en-export><note><title>Synthetic</title><content><![CDATA[<en-note><div>before</div><en-media type="image/png" hash="\(md5)"/><div>after</div><en-todo checked="true"/>done<en-todo checked="false"/>pending</en-note>]]></content><created>20200102T030405Z</created><updated>20210203T040506Z</updated><tag>work</tag><resource><data encoding="base64">\(bytes.base64EncodedString())</data><mime>image/png</mime><resource-attributes><file-name>image.png</file-name></resource-attributes></resource></note></en-export>
        """, "Collection.enex", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .evernote)
        let note = try #require(plan.snapshot.notes.first)
        let asset = try #require(plan.snapshot.assets.first)
        #expect(note.tags == ["work"])
        #expect(note.createdAt < note.updatedAt)
        #expect(note.markdown.range(of: "before")!.lowerBound < note.markdown.range(of: asset.reference)!.lowerBound)
        #expect(note.markdown.range(of: asset.reference)!.lowerBound < note.markdown.range(of: "after")!.lowerBound)
        #expect(note.markdown.contains("- [x]")); #expect(note.markdown.contains("- [ ]"))
        #expect(asset.data == bytes)
        #expect(plan.snapshot.folders.map(\.name) == ["Collection"])
    }
    @Test func sanitizesHTMLAndPreservesControlledStyles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("<h1>Title</h1><script>alert(1)</script><p onclick='x()'><span style='color: #ff0000; background-image:url(https://bad); text-decoration:underline'>colored</span><img src='https://example.com/x.png' onerror='x()'></p><iframe src='file:///etc/passwd'></iframe>", "rich.html", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        let text = try #require(plan.snapshot.notes.first?.markdown)
        #expect(text.contains("# Title")); #expect(text.contains("color: #ff0000"))
        #expect(!text.contains("script")); #expect(!text.contains("onclick")); #expect(!text.contains("background-image")); #expect(!text.contains("iframe"))
        #expect(plan.snapshot.assets.allSatisfy { $0.mimeType == "text/html" })
        #expect(plan.issues.contains { $0.message.contains("外部") })
    }
    @Test func preservesUnknownAndEncryptedSourcesWithoutFakeSuccess() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("unsupported proprietary envelope", "archive.notes", in: root)
        try put("<en-note><en-crypt cipher='AES'>opaque ciphertext</en-crypt></en-note>", "encrypted.enml", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .evernote)
        #expect(plan.issues.filter { $0.severity == .error }.count >= 2)
        #expect(plan.snapshot.assets.contains { $0.data == Data("unsupported proprietary envelope".utf8) })
        #expect(plan.snapshot.assets.contains { String(data: $0.data, encoding: .utf8)?.contains("opaque ciphertext") == true })
        #expect(!plan.snapshot.notes.contains { $0.markdown.contains("已解密") })
    }
    @Test func rejectsXMLExternalEntitiesAndMalformedXML() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("<!DOCTYPE en-export [<!ENTITY xxe SYSTEM 'file:///etc/passwd'>]><en-export><note><title>&xxe;</title></note></en-export>", "bad.enex", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .evernote)
        #expect(plan.issues.contains { $0.severity == .error })
        #expect(plan.snapshot.assets.count == 1)
        #expect(!plan.snapshot.notes.contains { $0.markdown.contains("root:") })
    }
    @Test func pdfOriginalAndPageTextArePreserved() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let document = PDFDocument()
        for index in 1...2 {
            let image = NSImage(size: NSSize(width: 300, height: 200))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0,y: 0,width: 300,height: 200).fill(); image.unlockFocus()
            let page = try #require(PDFPage(image: image)); document.insert(page, at: index - 1)
        }
        let bytes = try #require(document.dataRepresentation())
        try bytes.write(to: root.appendingPathComponent("Scanned.note.pdf"))
        let plan = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        #expect(plan.snapshot.assets.first?.data == bytes)
        #expect(plan.snapshot.assets.first?.kind == .pdf)
        #expect(plan.snapshot.notes.first?.markdown.contains("PDF") == true)
        #expect(plan.issues.contains { $0.message.contains("文本") })
    }
    @Test func cancellationReturnsNoPartialPlanAndFingerprintsAreStable() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("same content", "a.md", in: root); try put("same content", "b.md", in: root)
        #expect(throws: NotebookTransferError.self) { try NotebookTransfer.prepareImport(at: root, source: .markdown, cancelled: { true }) }
        let first = try NotebookTransfer.prepareImport(at: root, source: .markdown)
        let second = try NotebookTransfer.prepareImport(at: root, source: .markdown)
        #expect(first.snapshot.notes.map(\.sourceFingerprint) == second.snapshot.notes.map(\.sourceFingerprint))
        #expect(first.issues.contains { $0.message.contains("重复") })
    }
    @Test func exportUsesRealRelativeAssetsNestedFoldersAndUniqueNames() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = NoteFolder(name: "Folder")
        let note = NoteDocument(folderID: folder.id, title: "Same")
        let asset = NoteAsset(ownerNoteID: note.id, fileName: "a.png", mimeType: "image/png", kind: .image, data: Data("original".utf8))
        var first = note; first.markdown = "before ![a](\(asset.reference)) after"
        let second = NoteDocument(folderID: folder.id, title: "Same", markdown: "second")
        let snapshot = NotebookSnapshot(folders: [folder], notes: [first, second], assets: [asset])
        let output = try NotebookTransfer.export(snapshot: snapshot, to: root, format: .markdown)
        let files = try FileManager.default.subpathsOfDirectory(atPath: output.path)
        #expect(files.filter { $0.hasSuffix(".md") }.count == 2)
        let markdownURL = output.appendingPathComponent("Folder/Same.md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(!markdown.contains("workjournal-asset:"))
        let exportedAssets = files.filter { $0.hasSuffix(".png") }
        #expect(exportedAssets.count == 1)
        #expect(try Data(contentsOf: output.appendingPathComponent(exportedAssets[0])) == asset.data)
        let again = try NotebookTransfer.export(snapshot: snapshot, to: root, format: .html)
        #expect(again != output)
        let html = try String(contentsOf: again.appendingPathComponent("Folder/Same.html"), encoding: .utf8)
        #expect(html.contains("<img")); #expect(html.contains("assets/")); #expect(!html.contains("workjournal-asset:"))
    }
    @Test func preservesSelectablePDFTextAndCancelsBetweenPages() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 1...3 {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 30, y: 200)
            let text = NSAttributedString(string: "Synthetic selectable page \(index)", attributes: [.font: NSFont.systemFont(ofSize: 16)])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        try (output as Data).write(to: root.appendingPathComponent("text.pdf"))
        let plan = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        #expect(plan.snapshot.notes[0].markdown.contains("Synthetic selectable page 1"))
        #expect(plan.snapshot.notes[0].markdown.contains("Synthetic selectable page 3"))
        var pages = 0
        #expect(throws: NotebookTransferError.self) {
            try NotebookTransfer.prepareImport(at: root, source: .youdao, cancelled: { pages >= 2 }, progress: { if $0.contains("/") { pages += 1 } })
        }
    }
    @Test func rejectsOversizedSparseAssetBeforeReadingIt() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 * 1024 * 1024 + 1); try handle.close()
        #expect(throws: NotebookTransferError.self) { try NotebookTransfer.prepareImport(at: root, source: .youdao) }
    }
    @Test func exportCancellationRemovesStagingAndUnsafeHTMLNeverExecutes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let note = NoteDocument(title: "Unsafe", markdown: "<script>alert(1)</script><span onclick='evil()' style='color: red; background-image: url(https://bad)'>safe</span>\n\n![remote](https://example.com/a.png)")
        var calls = 0
        #expect(throws: NotebookTransferError.self) {
            try NotebookTransfer.export(snapshot: .init(notes: [note]), to: root, format: .html, cancelled: { calls += 1; return calls > 1 })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let result = try NotebookTransfer.export(snapshot: .init(notes: [note]), to: root, format: .html)
        let html = try String(contentsOf: result.appendingPathComponent("Unsafe.html"), encoding: .utf8)
        #expect(!html.contains("<script")); #expect(!html.contains("onclick")); #expect(!html.contains("background-image"))
        #expect(!html.contains("src=\"https:")); #expect(html.contains("color: red"))
    }
    @Test func nestedResourceFoldersAndMarkdownCodeStayLiteral() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("![nested](Example.note.attach/nested/a.png)\n\n```md\n![literal](missing.png)\n```", "Example.md", in: root)
        try put("nested bytes", "Example.note.attach/nested/a.png", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .markdown)
        #expect(plan.snapshot.notes.count == 1)
        #expect(plan.snapshot.assets.count == 1)
        #expect(!plan.issues.contains { $0.message.contains("missing.png") })
    }

    @Test func changedResourceBytesChangeFingerprintAndRetainUnreferencedNestedAttachments() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("![image](Example.note.attach/a.png)", "Example.md", in: root)
        try put("first", "Example.note.attach/a.png", in: root)
        try put("other", "Example.note.attach/nested/extra.bin", in: root)
        let first = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        try put("changed", "Example.note.attach/a.png", in: root)
        let second = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        #expect(first.snapshot.notes.count == 1)
        #expect(first.snapshot.assets.count == 2)
        #expect(first.snapshot.notes[0].sourceFingerprint != second.snapshot.notes[0].sourceFingerprint)
        #expect(first.snapshot.assets.allSatisfy { $0.ownerNoteID == first.snapshot.notes[0].id })
    }

    @Test func richHTMLStylesCodeAndMergedCellsSurviveExport() throws {
        let root = try fixture(); let output = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: output) }
        try put("<div style='text-align:center'><span style='color:#123456;background-color:yellow;text-decoration:underline'>styled</span><sub>sub</sub><sup>sup</sup></div><pre><code class='language-swift'>let a = 1\nlet b = 2</code></pre><table><tr><td colspan='2' rowspan='2'>merged</td></tr></table>", "rich.html", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        #expect(plan.snapshot.notes[0].markdown.contains("```swift"))
        #expect(plan.snapshot.notes[0].markdown.contains("colspan=\"2\""))
        let folder = try NotebookTransfer.export(snapshot: plan.snapshot, to: output, format: .html)
        let html = try String(contentsOf: folder.appendingPathComponent("rich.html"), encoding: .utf8)
        for value in ["text-align: center", "color: #123456", "background-color: yellow", "text-decoration: underline", "<sub>", "<sup>", "colspan=\"2\"", "rowspan=\"2\"", "language-swift"] { #expect(html.contains(value)) }
    }
    @Test func detectsENEXByNotesContentAndPreservesEncryptedResourceFailures() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("<en-export><note><title>Encrypted</title><content><![CDATA[<en-note><en-crypt>opaque</en-crypt><en-media type='image/png' hash='missing'/></en-note>]]></content><resource><data>invalid base64!</data><mime>image/png</mime></resource></note></en-export>", "synthetic.notes", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .evernote)
        #expect(plan.snapshot.notes.count == 1)
        #expect(plan.issues.contains { $0.severity == .error })
        #expect(plan.snapshot.assets.count == 1)
        #expect(String(data: plan.snapshot.assets[0].data, encoding: .utf8)?.contains("opaque") == true)
        #expect(plan.snapshot.notes[0].markdown.contains(plan.snapshot.assets[0].reference))
    }

    @Test func reportsAmbiguousAttachmentOwnersAndSupportsSingleFileAttachmentSelection() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("first", "Twin.md", in: root); try put("<p>second</p>", "Twin.html", in: root)
        try put("shared", "Twin.note.attach/image.png", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        #expect(plan.issues.contains { $0.severity == .error && $0.message.contains("归属") })
        try put("single", "Single.md", in: root)
        try put("nested", "Single.note.attach/nested/a.png", in: root)
        let single = try NotebookTransfer.prepareImport(at: root.appendingPathComponent("Single.md"), source: .youdao)
        #expect(single.snapshot.notes.count == 1)
        #expect(single.snapshot.assets.count == 1)
        #expect(single.snapshot.assets.first?.data == Data("nested".utf8))
    }
    @Test func rejectsUnknownENEXResourceEncodingWithoutInventingDecodedBytes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("<en-export><note><title>Unknown encoding</title><content><![CDATA[<en-note>text</en-note>]]></content><resource><data encoding='hex'>ffee</data><mime>image/png</mime></resource></note></en-export>", "encoding.enex", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .evernote)
        #expect(plan.issues.contains { $0.severity == .error })
        #expect(plan.snapshot.assets.count == 1)
        #expect(plan.snapshot.assets[0].mimeType == "application/xml")
    }

    @Test func repeatedPreparedImportsSkipStableFingerprintsButRetainChangedResourceBytes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try put("![image](Note.note.attach/a.png)", "Folder/Note.md", in: source)
        try put("first bytes", "Folder/Note.note.attach/a.png", in: source)
        let first = try NotebookTransfer.prepareImport(at: source, source: .youdao)
        let store = try JournalStore(url: root.appendingPathComponent("synthetic.sqlite"))
        #expect(try store.importNotebook(first.snapshot).notes == 1)
        let again = try NotebookTransfer.prepareImport(at: source, source: .youdao)
        #expect(first.snapshot.notes[0].id != again.snapshot.notes[0].id)
        let skipped = try store.importNotebook(again.snapshot)
        #expect(skipped.notes == 0); #expect(skipped.assets == 0); #expect(skipped.skipped > 0)
        #expect(try store.notes().count == 1); #expect(try store.noteFolders().count == 1)
        try put("changed bytes", "Folder/Note.note.attach/a.png", in: source)
        let changed = try NotebookTransfer.prepareImport(at: source, source: .youdao)
        #expect(try store.importNotebook(changed.snapshot).notes == 1)
        #expect(try store.notes().count == 2)
        #expect(try store.notebookSnapshot().assets.count == 2)
    }

    @Test func htmlExportRetainsGeneratedParentNoteLinksButRejectsUntrustedTraversal() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = NoteFolder(name: "Child")
        let target = NoteDocument(title: "Target", markdown: "destination")
        let source = NoteDocument(folderID: folder.id, title: "Source", markdown: "[Target](workjournal-note://\(target.id.uuidString.lowercased())) [unsafe](../../outside.html)")
        let output = try NotebookTransfer.export(snapshot: .init(folders: [folder], notes: [source, target]), to: root, format: .html)
        let html = try String(contentsOf: output.appendingPathComponent("Child/Source.html"), encoding: .utf8)
        #expect(html.contains("href=\"../Target.html\""))
        #expect(!html.contains("href=\"../../outside.html\""))
        #expect(!NotebookHTML.safeLink("../Target.html", allowRelative: true))
    }
    @Test func markdownImportsReferenceImagesLinksEscapedDestinationsAndIgnoresCode() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("picture bytes", "image (one).png", in: root)
        try put("attachment bytes", "file two.bin", in: root)
        try put("inline bytes", "inline(three).png", in: root)
        let markdown = "![picture][IMG] [file][file]\n\n[img]: <image (one).png> \"title\"\n[file]: file\\ two.bin\n\n![inline](inline(three).png)\n\n```md\n![literal][missing]\n[missing]: missing.png\n<img src='missing-too.png'>\n```\n"
        try put(markdown, "note.md", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root.appendingPathComponent("note.md"), source: .markdown)
        #expect(plan.snapshot.notes.count == 1); #expect(plan.snapshot.assets.count == 3)
        #expect(plan.issues.isEmpty)
        #expect(plan.snapshot.notes[0].markdown.contains("![picture][IMG]"))
        #expect(plan.snapshot.notes[0].markdown.contains("[missing]: missing.png"))
        #expect(plan.snapshot.notes[0].markdown.contains("<img src='missing-too.png'>"))
        for asset in plan.snapshot.assets { #expect(plan.snapshot.notes[0].markdown.contains(asset.reference)) }
    }
    @Test func htmlTextLiteralsRemainLiteralMarkdownAndHTMLAfterRoundTrip() throws {
        let root = try fixture(); let destination = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        try put("<p>Show &lt;span&gt;name&lt;/span&gt; and *literal* and [label](file.png)</p><p># heading? - item? &amp; value</p>", "literal.html", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .youdao)
        let markdown = plan.snapshot.notes[0].markdown
        #expect(markdown.contains("\\<span\\>name\\<\\/span\\>"))
        #expect(markdown.contains("\\*literal\\*"))
        let output = try NotebookTransfer.export(snapshot: plan.snapshot, to: destination, format: .html)
        let html = try String(contentsOf: output.appendingPathComponent("literal.html"), encoding: .utf8)
        #expect(html.contains("&lt;span&gt;name&lt;/span&gt; and *literal*"))
        #expect(!html.contains("<em>literal</em>")); #expect(!html.contains("<span>name</span>"))
        #expect(html.contains("[label](file.png)"))
    }
    @Test func markdownDocumentLinksMapToImportedIdentitiesAndCodeStaysLiteral() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try put("[Target](Target.md)\n\n`[literal](Target.md)`", "Source.md", in: root)
        try put("destination", "Target.md", in: root)
        let plan = try NotebookTransfer.prepareImport(at: root, source: .markdown)
        let target = try #require(plan.snapshot.notes.first { $0.title == "Target" })
        let source = try #require(plan.snapshot.notes.first { $0.title == "Source" })
        #expect(source.markdown.contains("[Target](workjournal-note://\(target.id.uuidString.lowercased()))"))
        #expect(source.markdown.contains("`[literal](Target.md)`"))
        #expect(plan.snapshot.assets.isEmpty)
        #expect(NotebookHTML.safeLink("workjournal-note://" + target.id.uuidString.lowercased()))
        #expect(!NotebookHTML.safeLink("workjournal-note://bad-id"))
    }

    @Test func htmlExportPreservesBackslashesInsideSingleAndMultipleBacktickCodeSpans() throws {
        let root = try fixture(); let source = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let note = NoteDocument(title: "Code", markdown: #"`a\*b` and ``a`b\*c`` and ordinary \*literal\*"#)
        let output = try NotebookTransfer.export(snapshot: .init(notes: [note]), to: root, format: .html)
        let html = try String(contentsOf: output.appendingPathComponent("Code.html"), encoding: .utf8)
        #expect(html.contains(#"<code>a\*b</code>"#))
        #expect(html.contains(#"<code>a`b\*c</code>"#))
        #expect(html.contains("ordinary *literal*")); #expect(!html.contains("<em>literal</em>"))
        try put(#"<p><code>a\*b</code> and <code>a`b\*c</code></p>"#, "Imported.html", in: source)
        let plan = try NotebookTransfer.prepareImport(at: source, source: .youdao)
        let importedOutput = try NotebookTransfer.export(snapshot: plan.snapshot, to: root, format: .html)
        let imported = try String(contentsOf: importedOutput.appendingPathComponent("Imported.html"), encoding: .utf8)
        #expect(imported.contains(#"<code>a\*b</code>"#))
        #expect(imported.contains(#"<code>a`b\*c</code>"#))
    }

    @Test func escapedBacktickDelimitersRemainTextAndCodeClosersKeepLiteralBackslashes() throws {
        let root = try fixture(); let source = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let cases: [(String, String, Bool)] = [
            (#"Use \`tick\` literally"#, "Use `tick` literally", false),
            (#"Use \\`a\*b` literally"#, #"Use \<code>a\*b</code> literally"#, true),
            (#"Use \\\`tick\` literally"#, #"Use \`tick` literally"#, false),
            (#"real `a\` tail"#, #"real <code>a\</code> tail"#, true),
            (#"real ``a\`b`` tail"#, #"real <code>a\`b</code> tail"#, true),
            (#"unmatched `a\*b"#, "unmatched `a*b", false),
            (#"\`escaped then `unmatched"#, "`escaped then `unmatched", false),
            (#"\``tick\``"#, "``tick``", false)
        ]
        for (markdown, expected, hasCode) in cases {
            let html = try NotebookHTML.renderMarkdown(markdown)
            #expect(html.contains(expected))
            #expect(html.contains("<code>") == hasCode)
        }
        try put("<p>Use `tick` literally</p>", "Literal ticks.html", in: source)
        let plan = try NotebookTransfer.prepareImport(at: source, source: .youdao)
        let output = try NotebookTransfer.export(snapshot: plan.snapshot, to: root, format: .html)
        let html = try String(contentsOf: output.appendingPathComponent("Literal ticks.html"), encoding: .utf8)
        #expect(html.contains("Use `tick` literally")); #expect(!html.contains("<code>"))
    }

}
