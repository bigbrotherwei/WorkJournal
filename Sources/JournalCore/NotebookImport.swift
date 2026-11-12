import Foundation
import CryptoKit
import PDFKit

public enum NotebookImportSource: String, CaseIterable, Codable, Sendable { case youdao, evernote, markdown }
public enum NotebookExportFormat: String, CaseIterable, Codable, Sendable { case markdown, html }
public struct NotebookImportIssue: Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case warning, error }
    public var severity: Severity
    public var sourcePath: String
    public var message: String
    public init(severity: Severity, sourcePath: String, message: String) { self.severity = severity; self.sourcePath = sourcePath; self.message = message }
}
public struct NotebookImportPlan: Sendable {
    public var snapshot: NotebookSnapshot
    public var issues: [NotebookImportIssue]
    public var noteCount: Int { snapshot.notes.count }
    public var assetCount: Int { snapshot.assets.count }
    public var folderCount: Int { snapshot.folders.count }
    public var preservedFileCount: Int
    public var editableNoteCount: Int
    public var totalBytes: Int { snapshot.assets.reduce(0) { $0 + $1.data.count } + snapshot.notes.reduce(0) { $0 + $1.markdown.utf8.count } }
}
public enum NotebookTransferError: Error, LocalizedError, Equatable {
    case cancelled, invalidSource, limitExceeded(String), invalidSnapshot(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消导入或导出。"
        case .invalidSource: return "请选择可读取的本地文件或目录。"
        case .limitExceeded(let detail): return "超过笔记资源限制：\(detail)"
        case .invalidSnapshot(let detail): return "笔记结构无效：\(detail)"
        }
    }
}
public enum NotebookTransfer {
    public static func prepareImport(at url: URL, source: NotebookImportSource, cancelled: @escaping () -> Bool = { false }, progress: @escaping (String) -> Void = { _ in }) throws -> NotebookImportPlan {
        try NotebookImporter(url: url, source: source, cancelled: cancelled, progress: progress).run()
    }
}

final class NotebookImporter {
    let selected: URL
    let root: URL
    let source: NotebookImportSource
    let cancelled: () -> Bool
    let progress: (String) -> Void
    var snapshot = NotebookSnapshot()
    var issues: [NotebookImportIssue] = []
    var folderIDs: [String: UUID] = [:]
    var documentIDs: [String: UUID] = [:]
    var consumed: Set<String> = []
    var fingerprints: Set<String> = []
    var allFiles: [URL] = []
    var totalRead = 0
    var ambiguousAttachmentPaths: Set<String> = []
    var preserved = 0
    var editable = 0
    init(url: URL, source: NotebookImportSource, cancelled: @escaping () -> Bool, progress: @escaping (String) -> Void) {
        selected = url.standardizedFileURL; self.source = source; self.cancelled = cancelled; self.progress = progress
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: selected.path, isDirectory: &directory)
        root = directory.boolValue ? selected : selected.deletingLastPathComponent()
    }
    func check() throws { if cancelled() { throw NotebookTransferError.cancelled } }
    func relative(_ url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    func issue(_ url: URL, _ message: String, _ severity: NotebookImportIssue.Severity = .warning) { issues.append(.init(severity: severity, sourcePath: relative(url), message: message)) }
    func safe(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else { return false }
        var current = url.standardizedFileURL
        while current.path != root.deletingLastPathComponent().path {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            if current.path == root.path { break }; current.deleteLastPathComponent()
        }
        return true
    }
    func data(_ url: URL, limit: Int = 128 * 1024 * 1024) throws -> Data {
        try check()
        guard safe(url) else { throw NotebookTransferError.invalidSource }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit, totalRead + size <= 1024 * 1024 * 1024 else { throw NotebookTransferError.limitExceeded(relative(url)) }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= limit else { throw NotebookTransferError.limitExceeded(relative(url)) }
        totalRead += bytes.count
        consumed.insert(url.standardizedFileURL.path)
        return bytes
    }
    func run() throws -> NotebookImportPlan {
        try check()
        guard safe(selected), FileManager.default.fileExists(atPath: selected.path) else { throw NotebookTransferError.invalidSource }
        let values = try selected.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true { try walk(selected, depth: 0) } else {
            allFiles = [selected]
            for resourceDirectory in attachmentDirectories(for: selected) where FileManager.default.fileExists(atPath: resourceDirectory.path) {
                guard safe(resourceDirectory), (try? resourceDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { issue(resourceDirectory, "不安全的附件目录已拒绝。", .error); continue }
                try walk(resourceDirectory, depth: 0)
            }
        }
        let documents = allFiles.filter { ["md", "markdown", "pdf", "html", "htm", "enex", "enml", "notes"].contains($0.pathExtension.lowercased()) && !relative($0).split(separator: "/").contains(where: { $0.hasSuffix(".attach") }) }
        for file in documents where !["enex", "notes"].contains(file.pathExtension.lowercased()) { documentIDs[file.path] = UUID() }
        var attachmentOwners: [String: [URL]] = [:]
        for file in documents {
            for directory in attachmentDirectories(for: file) { attachmentOwners[directory.path, default: []].append(file) }
        }
        for (path, owners) in attachmentOwners where owners.count > 1 && FileManager.default.fileExists(atPath: path) {
            ambiguousAttachmentPaths.insert(path)
            issue(URL(fileURLWithPath: path), "同名笔记匹配多个附件目录归属；仅解析明确引用，其余原文件单独保留，需检查。", .error)
        }
        for file in documents {
            try check(); progress(relative(file))
            switch file.pathExtension.lowercased() {
            case "enex": try importENEX(file)
            case "notes":
                let bytes = try data(file)
                if let string = String(data: bytes, encoding: .utf8), string.contains("<en-export"), !string.contains("<!ENTITY") { try importENEX(file, bytes: bytes) }
                else { try preserve(file, bytes: bytes, message: "无法识别的 .notes 封装；已保留原文件，尚未完成转换。") }
            default: try importDocument(file)
            }
        }
        for file in allFiles where !consumed.contains(file.standardizedFileURL.path) {
            try check()
            try preserve(file, message: "未找到明确归属或不支持的文件；已保留原文件，需检查。")
        }
        try NotebookValidation.validate(snapshot)
        return NotebookImportPlan(snapshot: snapshot, issues: issues, preservedFileCount: preserved, editableNoteCount: editable)
    }
    func walk(_ directory: URL, depth: Int) throws {
        try check()
        guard depth <= 17 else { throw NotebookTransferError.limitExceeded("目录深度") }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try check()
            guard safe(url) else { issue(url, "符号链接或越界路径已拒绝。", .error); continue }
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try walk(url, depth: depth + 1) } else { allFiles.append(url.standardizedFileURL) }
        }
    }
    func folder(_ url: URL) throws -> UUID? {
        let path = relative(url)
        if path.isEmpty { return nil }
        if let id = folderIDs[path] { return id }
        let components = path.split(separator: "/")
        guard components.count <= 16 else { throw NotebookTransferError.limitExceeded("目录深度") }
        // Resource directories are attachments, never notebooks.
        if components.contains(where: { $0.hasSuffix(".attach") }) { return try folder(url.deletingLastPathComponent()) }
        let parent = try folder(url.deletingLastPathComponent())
        let item = NoteFolder(parentID: parent, name: String(url.lastPathComponent.prefix(120)))
        snapshot.folders.append(item); folderIDs[path] = item.id
        return item.id
    }
    func fingerprint(_ bytes: Data) -> String { source.rawValue + ":" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    func append(_ input: NoteDocument, editable: Bool) throws {
        var note = input
        let resources = snapshot.assets.filter { $0.ownerNoteID == note.id }.sorted { $0.fileName < $1.fileName }
        if !resources.isEmpty, let original = note.sourceFingerprint {
            var combined = Data(original.utf8)
            for item in resources { combined.append(Data(item.fileName.utf8)); combined.append(Data(SHA256.hash(data: item.data))) }
            note.sourceFingerprint = fingerprint(combined)
        }
        guard snapshot.notes.count < 10_000, note.markdown.utf8.count <= 8 * 1024 * 1024 else { throw NotebookTransferError.limitExceeded("笔记数量或正文大小") }
        if let hash = note.sourceFingerprint, !fingerprints.insert(hash).inserted { issues.append(.init(severity: .warning, sourcePath: "", message: "发现重复内容指纹；保留独立笔记，提交时可选择跳过重复内容。")) }
        snapshot.notes.append(note); if editable { self.editable += 1 }
    }
    func asset(_ bytes: Data, owner: UUID, name: String, mime: String? = nil) throws -> NoteAsset {
        guard bytes.count <= 128 * 1024 * 1024, snapshot.assets.count < 20_000, snapshot.assets.reduce(0, { $0 + $1.data.count }) + bytes.count <= 1024 * 1024 * 1024 else { throw NotebookTransferError.limitExceeded("附件数量或大小") }
        let type = mime ?? Self.mime(name)
        let item = NoteAsset(ownerNoteID: owner, fileName: name, mimeType: type, kind: type.hasPrefix("image/") ? .image : type == "application/pdf" ? .pdf : .attachment, data: bytes)
        snapshot.assets.append(item); return item
    }
    static func mime(_ name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "html", "htm": return "text/html"
        case "md", "markdown": return "text/markdown"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
    func preserve(_ file: URL, bytes: Data? = nil, message: String) throws {
        let raw = try bytes ?? data(file)
        var note = NoteDocument(folderID: try folder(file.deletingLastPathComponent()), title: String(file.deletingPathExtension().lastPathComponent.prefix(500)), source: source.rawValue + ":preserved", sourceFingerprint: fingerprint(raw))
        let original = try asset(raw, owner: note.id, name: file.lastPathComponent)
        note.markdown = "> 未完成转换：\(message)\n\n[原文件](\(original.reference))"
        try append(note, editable: false); preserved += 1; issue(file, message, .error)
    }
    func resolve(_ reference: String, from file: URL, owner: UUID, cache: inout [String: String], allowNoteLink: Bool = false) throws -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = URL(string: trimmed)?.scheme, !scheme.isEmpty {
            issue(file, scheme == "http" || scheme == "https" ? "外部资源仅保留链接；未联网下载。" : "不安全或无法解析的资源协议已拒绝。")
            return nil
        }
        let path = trimmed.removingPercentEncoding ?? trimmed
        guard !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\") else { issue(file, "越界资源引用已拒绝。", .error); return nil }
        let url = file.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        guard safe(url), FileManager.default.fileExists(atPath: url.path), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { issue(file, "资源缺失、符号链接或无法读取：\(path)", .error); return nil }
        if allowNoteLink, let noteID = documentIDs[url.path] { return "workjournal-note://" + noteID.uuidString.lowercased() }
        if let previous = cache[url.path] { return previous }
        let item = try asset(data(url), owner: owner, name: url.lastPathComponent)
        cache[url.path] = item.reference; return item.reference
    }
    func importDocument(_ file: URL) throws {
        let bytes = try data(file)
        let attributes = try file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        var title = file.deletingPathExtension().lastPathComponent
        if title.hasSuffix(".note") { title = String(title.dropLast(5)) }
        var note = NoteDocument(id: documentIDs[file.path] ?? UUID(), folderID: try folder(file.deletingLastPathComponent()), title: String(title.prefix(500)), createdAt: attributes.creationDate ?? Date(), updatedAt: attributes.contentModificationDate ?? Date(), source: source.rawValue, sourceFingerprint: fingerprint(bytes))
        var cache: [String: String] = [:]
        if file.pathExtension.lowercased() == "pdf" {
            let original = try asset(bytes, owner: note.id, name: file.lastPathComponent, mime: "application/pdf")
            guard let pdf = PDFDocument(data: bytes), !pdf.isLocked else { try preservePDF(&note, original: original, file: file); return }
            var parts = ["> 以下为 PDF 文本层提取内容；图片、扫描页和复杂排版请查看原 PDF。", "[查看原 PDF](\(original.reference))"]
            for page in 0..<pdf.pageCount {
                try check(); progress("\(relative(file)) · \(page + 1)/\(pdf.pageCount)")
                let text = pdf.page(at: page)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                parts.append("## 第 \(page + 1) 页\n\n" + (text.isEmpty ? "（此页无可提取文本，请查看原 PDF。）" : text))
                if parts.reduce(0, { $0 + $1.utf8.count }) > 8 * 1024 * 1024 { throw NotebookTransferError.limitExceeded("PDF 提取正文大小") }
            }
            note.markdown = parts.joined(separator: "\n\n")
            issue(file, "PDF 仅提取文本层；原始图片、代码语言、表格和任务语义保留在原文件中供对照。")
        } else {
            guard let raw = String(data: bytes, encoding: .utf8) else { try preserve(file, bytes: bytes, message: "无法解码 UTF-8 正文；已保留原文件。"); return }
            if ["html", "htm", "enml"].contains(file.pathExtension.lowercased()) {
                let result = try NotebookHTML.importHTML(raw, resource: { reference in try self.resolve(reference, from: file, owner: note.id, cache: &cache) }, noteLink: { reference in
                    guard let url = self.localReference(reference, from: file), let id = self.documentIDs[url.path] else { return nil }
                    return "workjournal-note://" + id.uuidString.lowercased()
                })
                note.markdown = result.markdown
                for message in result.warnings { issue(file, message) }
                if result.requiresOriginal {
                    let original = try asset(bytes, owner: note.id, name: file.lastPathComponent)
                    note.markdown += "\n\n[保留的原文件](\(original.reference))"; preserved += 1
                    issue(file, "检测到加密块或不支持的专有内容，已保留原文，尚未完成转换。", .error)
                }
            } else { note.markdown = try rewriteMarkdown(raw, file: file, owner: note.id, cache: &cache) }
        }
        // Some Youdao PDF notes have same-name resources even without textual references.
        let directories = attachmentDirectories(for: file).filter { !ambiguousAttachmentPaths.contains($0.path) }
        for attachment in allFiles where directories.contains(where: { attachment.path.hasPrefix($0.path + "/") }) {
            if cache[attachment.path] == nil && !consumed.contains(attachment.standardizedFileURL.path) {
                let item = try asset(data(attachment), owner: note.id, name: attachment.lastPathComponent)
                note.markdown += "\n\n" + (item.kind == .image ? "!" : "") + "[\(NotebookHTML.escapeMarkdown(item.fileName))](\(item.reference))"
                cache[attachment.path] = item.reference
            }
        }
        try append(note, editable: true)
    }
    func attachmentDirectories(for file: URL) -> [URL] {
        guard ["md", "markdown", "html", "htm", "pdf", "enml"].contains(file.pathExtension.lowercased()) else { return [] }
        let stem = file.deletingPathExtension().lastPathComponent
        let names = Set([stem + ".attach", (stem.hasSuffix(".note") ? stem : stem + ".note") + ".attach"])
        return names.sorted().map { file.deletingLastPathComponent().appendingPathComponent($0).standardizedFileURL }
    }
    func preservePDF(_ note: inout NoteDocument, original: NoteAsset, file: URL) throws {
        note.markdown = "> PDF 无法解码或已加密；原文件已完整保留。\n\n[原 PDF](\(original.reference))"
        try append(note, editable: false); preserved += 1; issue(file, "PDF 无法解码或已加密，未提取文本。", .error)
    }
    func localReference(_ reference: String, from file: URL) -> URL? {
        guard URL(string: reference)?.scheme == nil else { return nil }
        let path = reference.removingPercentEncoding ?? reference
        guard !path.hasPrefix("/"), !path.contains("\\") else { return nil }
        let url = file.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        return safe(url) ? url : nil
    }
    func rewriteMarkdown(_ raw: String, file: URL, owner: UUID, cache: inout [String: String]) throws -> String {
        let scan = try NotebookMarkdownReferences.scan(raw)
        var replacements: [(NSRange, String)] = []
        for destination in scan.destinations {
            if let target = try resolve(destination.value, from: file, owner: owner, cache: &cache, allowNoteLink: !destination.isImage) {
                replacements.append((destination.range, target))
            }
        }
        for label in scan.missingLabels { issue(file, "Markdown 引用定义缺失：\(label)", .error) }
        // All ranges refer to the original source, so earlier edits never shift code exclusions.
        let imageRegex = try NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#)
        for match in imageRegex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard !scan.literalRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: raw) else { continue }
            let converted = try NotebookHTML.importHTML(String(raw[range]), resource: { try self.resolve($0, from: file, owner: owner, cache: &cache) })
            replacements.append((match.range, converted.markdown))
        }
        var result = raw
        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            if let range = Range(range, in: result) { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
