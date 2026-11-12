import Foundation
import CryptoKit

private struct ENEXResource { var base64 = ""; var mime = ""; var name = ""; var encoding = "base64" }
private struct ENEXNote {
    var title = ""; var content = ""; var created = ""; var updated = ""; var tags: [String] = []; var resources: [ENEXResource] = []; var guid = ""
}
private final class ENEXReader: NSObject, XMLParserDelegate {
    var notes: [ENEXNote] = []
    var note: ENEXNote?
    var resource: ENEXResource?
    var stack: [String] = []
    var text = ""
    var failed = false
    let cancelled: () -> Bool
    init(cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if cancelled() || stack.count > 128 || notes.count >= 10_000 { failed = true; parser.abortParsing(); return }
        stack.append(elementName); text = ""
        if elementName == "note" { note = ENEXNote() }
        if elementName == "resource" { resource = ENEXResource() }
        if elementName == "data" { resource?.encoding = attributeDict["encoding"] ?? "base64" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if cancelled() { parser.abortParsing(); return }
        text += string
        if text.utf8.count > 180 * 1024 * 1024 { failed = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if let string = String(data: CDATABlock, encoding: .utf8) { text += string } else { failed = true; parser.abortParsing() } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if resource != nil {
            switch elementName {
            case "data": resource?.base64 = text
            case "mime": resource?.mime = text
            case "file-name": resource?.name = text
            case "resource": if let resource { note?.resources.append(resource) }; resource = nil
            default: break
            }
        } else {
            switch elementName {
            case "title": note?.title = text
            case "content": note?.content = text
            case "created": note?.created = text
            case "updated": note?.updated = text
            case "tag": note?.tags.append(text)
            case "guid": note?.guid = text
            case "note": if let note { notes.append(note) }; note = nil
            default: break
            }
        }
        if !stack.isEmpty { stack.removeLast() }; text = ""
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { failed = true; parser.abortParsing(); return nil }
}

extension NotebookImporter {
    func importENEX(_ file: URL, bytes supplied: Data? = nil) throws {
        let bytes = try supplied ?? data(file, limit: 1024 * 1024 * 1024)
        guard let xml = String(data: bytes, encoding: .utf8), xml.contains("<en-export"), !xml.uppercased().contains("<!ENTITY"), !xml.contains("<![INCLUDE[") else {
            try preserve(file, bytes: bytes, message: "ENEX 无法识别或包含禁止的 XML 实体；已保留原文件，尚未转换。"); return
        }
        let reader = ENEXReader(cancelled: cancelled)
        let parser = XMLParser(data: bytes); parser.shouldResolveExternalEntities = false; parser.delegate = reader
        let valid = parser.parse()
        try check()
        guard valid, !reader.failed, !reader.notes.isEmpty else { try preserve(file, bytes: bytes, message: "ENEX XML 损坏或没有可识别笔记；已保留原文件，尚未转换。"); return }
        let exportFolder = NoteFolder(parentID: try folder(file.deletingLastPathComponent()), name: String(file.deletingPathExtension().lastPathComponent.prefix(120)))
        snapshot.folders.append(exportFolder)
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let ids = reader.notes.map { _ in UUID() }
        var guidMap: [String: UUID] = [:]
        for (index, sourceNote) in reader.notes.enumerated() where !sourceNote.guid.isEmpty { guidMap[sourceNote.guid.lowercased()] = ids[index] }
        for (index, sourceNote) in reader.notes.enumerated() {
            try check(); progress("\(relative(file)) · \(index + 1)/\(reader.notes.count)")
            let fingerprintBytes = Data((sourceNote.title + "\n" + sourceNote.content + "\n" + sourceNote.resources.map(\.base64).joined()).utf8)
            var note = NoteDocument(id: ids[index], folderID: exportFolder.id, title: String((sourceNote.title.isEmpty ? "未命名笔记" : sourceNote.title).prefix(500)), createdAt: date.date(from: sourceNote.created) ?? Date(), updatedAt: date.date(from: sourceNote.updated) ?? date.date(from: sourceNote.created) ?? Date(), tags: sourceNote.tags, source: source.rawValue + ":enex", sourceFingerprint: fingerprint(fingerprintBytes))
            var media: [String: String] = [:]
            var resources: [NoteAsset] = []
            var invalid = false
            for (resourceIndex, resource) in sourceNote.resources.enumerated() {
                try check()
                let encoded = resource.base64.filter { !$0.isWhitespace }
                guard resource.encoding.lowercased() == "base64", encoded.utf8.count <= 180 * 1024 * 1024, let raw = Data(base64Encoded: encoded) else { invalid = true; issue(file, "ENEX 附件编码不支持或 Base64 无法解码；已保留原始 ENEX。", .error); continue }
                let name = resource.name.isEmpty ? "attachment-\(resourceIndex + 1).\(resource.mime.split(separator: "/").last.map(String.init) ?? "bin")" : URL(fileURLWithPath: resource.name).lastPathComponent
                let item = try asset(raw, owner: note.id, name: name, mime: resource.mime.isEmpty ? nil : resource.mime)
                let hash = Insecure.MD5.hash(data: raw).map { String(format: "%02x", $0) }.joined()
                media[hash] = item.reference; resources.append(item)
            }
            let result = try NotebookHTML.importHTML(sourceNote.content, resource: { reference in
                if reference.hasPrefix("http://") || reference.hasPrefix("https://") { self.issue(file, "外部资源仅保留链接；未联网下载。") }
                return nil
            }, media: media)
            note.markdown = result.markdown
            for message in result.warnings { issue(file, message) }
            for resource in resources where !note.markdown.contains(resource.reference) {
                note.markdown += "\n\n[\(NotebookHTML.escapeMarkdown(resource.fileName))](\(resource.reference))"
                issue(file, "附件未在正文中找到 MD5 引用，已作为笔记附件保留。")
            }
            // ENEX does not reliably include GUIDs. Rewrite only identities explicitly supplied by this export.
            let links = try NSRegularExpression(pattern: #"evernote:///[^\s\)\"<>]+"#)
            for match in links.matches(in: note.markdown, range: NSRange(note.markdown.startIndex..., in: note.markdown)).reversed() {
                guard let range = Range(match.range, in: note.markdown) else { continue }
                let value = String(note.markdown[range])
                let parts = value.split(separator: "/").map(String.init)
                if let guid = parts.last(where: { guidMap[$0.lowercased()] != nil }), let id = guidMap[guid.lowercased()] { note.markdown.replaceSubrange(range, with: "workjournal-note://" + id.uuidString.lowercased()) }
                else { issue(file, "内部笔记链接缺少可靠身份对应，已保留原链接。") }
            }
            if result.requiresOriginal || invalid {
                let original = try asset(bytes, owner: note.id, name: file.lastPathComponent, mime: "application/xml")
                note.markdown += "\n\n[保留的原始 ENEX](\(original.reference))"; preserved += 1
                issue(file, "加密或未转换内容已保留在原始 ENEX；此笔记需要检查。", .error)
            }
            try append(note, editable: true)
        }
        issue(file, "ENEX 未提供完整目录树；按导出文件名创建笔记本。")
    }
}
