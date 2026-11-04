import SwiftUI
import AppKit
import JournalCore

final class RecordAttachment: NSTextAttachment {
    var item: ImageAttachment?
}
@MainActor final class RecordEditorBridge: ObservableObject {
    weak var editor: InlineTextView?
    var failure: (String) -> Void = { _ in }
    func insert(_ items: [ImageAttachment]) {
        guard let editor else { return }
        do {
            let existing = editor.currentImages()
            try ImageAttachment.validate(existing + items)
            let content = NSMutableAttributedString(string: "")
            for item in items {
                content.append(NSAttributedString(string: "\n"))
                content.append(InlineTextView.picture(item))
                content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 15)]))
            }
            editor.insertText(content, replacementRange: editor.selectedRange())
            editor.window?.makeFirstResponder(editor)
        } catch { failure(error.localizedDescription) }
    }
    func paste() { do { insert([try ImageImport.pasted()]) } catch { failure(error.localizedDescription) } }
    func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            do { self.insert(try panel.urls.map { try ImageImport.fromFile($0) }) }
            catch { self.failure(error.localizedDescription) }
        }
    }
}
final class InlineTextView: NSTextView {
    weak var bridge: RecordEditorBridge?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
    static func picture(_ item: ImageAttachment) -> NSAttributedString {
        let attachment = RecordAttachment()
        attachment.item = item; attachment.image = NSImage(data: item.data)
        let size = attachment.image?.size ?? NSSize(width: 200, height: 150)
        let scale = min(1, 300 / max(1, size.width), 160 / max(1, size.height))
        attachment.bounds = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        return NSAttributedString(attachment: attachment)
    }
    func currentImages() -> [ImageAttachment] {
        var items: [ImageAttachment] = []
        textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage?.length ?? 0)) { value, _, _ in
            if let item = (value as? RecordAttachment)?.item, !items.contains(where: { $0.id == item.id }) { items.append(item) }
        }
        return items
    }
    private static let contentType = NSPasteboard.PasteboardType("app.workjournal.inline-content")
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let selected = storage.attributedSubstring(from: selectedRange())
        var text = "", images: [ImageAttachment] = []
        selected.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
            if let item = (value as? RecordAttachment)?.item {
                text += RecordContent.marker(item.id)
                if !images.contains(where: { $0.id == item.id }) { images.append(item) }
            } else { text += (selected.string as NSString).substring(with: range) }
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(RecordContent.plainText(text), forType: .string)
        if let data = try? JSONEncoder().encode(RecordDraft(text: text, images: images)) { board.setData(data, forType: Self.contentType) }
    }
    override func cut(_ sender: Any?) { copy(sender); insertText("", replacementRange: selectedRange()) }
    override func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.data(forType: Self.contentType) {
            do {
                let content = try JSONDecoder().decode(RecordDraft.self, from: data)
                try ImageAttachment.validate(content.images)
                let result = NSMutableAttributedString(string: "")
                var added: [ImageAttachment] = []
                for part in RecordContent.parts(content.text) {
                    switch part {
                    case .text(let value): result.append(NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]))
                    case .image(let id):
                        if var item = content.images.first(where: { $0.id == id }) { item.id = UUID(); added.append(item); result.append(Self.picture(item)) }
                    }
                }
                try ImageAttachment.validate(currentImages() + added)
                insertText(result, replacementRange: selectedRange())
            } catch { bridge?.failure(error.localizedDescription) }
        } else if NSPasteboard.general.data(forType: .png) != nil || NSPasteboard.general.data(forType: .tiff) != nil {
            bridge?.paste()
        } else if let text = NSPasteboard.general.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }
}
struct InlineRecordEditor: View {
    var text: String
    var images: [ImageAttachment]
    var changed: (String, [ImageAttachment]) -> Void
    var onError: (String) -> Void
    @StateObject private var bridge = RecordEditorBridge()
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeRecordEditor(text: text, images: images, bridge: bridge, changed: changed)
            HStack {
                Button { bridge.choose() } label: { Label("插入图片", systemImage: "photo.badge.plus") }
                Button { bridge.paste() } label: { Label("粘贴图片", systemImage: "doc.on.clipboard") }
                Spacer()
                Text("\(images.count)/4 张 · 图片仅存本机").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { bridge.failure = onError }
    }
}
struct NativeRecordEditor: NSViewRepresentable {
    let text: String
    let images: [ImageAttachment]
    let bridge: RecordEditorBridge
    var changed: (String, [ImageAttachment]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = InlineTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        editor.isRichText = true; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false; editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("记录内容，支持图文混排")
        editor.delegate = context.coordinator; editor.bridge = bridge; bridge.editor = editor
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? InlineTextView else { return }
        bridge.editor = editor
        guard context.coordinator.last != RecordDraft(text: text, images: images) else { return }
        let result = NSMutableAttributedString(string: "")
        for part in RecordContent.parts(text) {
            switch part {
            case .text(let value): result.append(NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]))
            case .image(let id): if let item = images.first(where: { $0.id == id }) { result.append(InlineTextView.picture(item)) }
            }
        }
        let selection = editor.selectedRange()
        editor.textStorage?.setAttributedString(result)
        editor.setSelectedRange(NSRange(location: min(selection.location, result.length), length: 0))
        context.coordinator.last = RecordDraft(text: text, images: images)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeRecordEditor
        var last: RecordDraft?
        init(_ parent: NativeRecordEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? InlineTextView, let storage = editor.textStorage else { return }
            var text = ""
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let item = (value as? RecordAttachment)?.item { text += RecordContent.marker(item.id) }
                else { text += (storage.string as NSString).substring(with: range) }
            }
            let images = editor.currentImages()
            last = RecordDraft(text: text, images: images)
            parent.changed(text, images)
        }
    }
}
struct RecordContentView: View {
    let entry: Entry
    @ViewState private var preview: ImageAttachment?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(RecordContent.parts(entry.text).enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let value):
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(value.trimmingCharacters(in: .newlines)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    }
                case .image(let id):
                    if let item = entry.images.first(where: { $0.id == id }), let image = NSImage(data: item.data) {
                        Button { preview = item } label: { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220) }
                            .buttonStyle(.plain).accessibilityLabel("查看图片：" + item.name)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $preview) { item in
            VStack {
                HStack { Text(item.name); Spacer(); Button("关闭") { preview = nil } }
                if let image = NSImage(data: item.data) { Image(nsImage: image).resizable().scaledToFit() }
            }.padding().frame(width: 680, height: 500)
        }
    }
}
