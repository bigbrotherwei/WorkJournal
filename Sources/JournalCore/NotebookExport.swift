import Foundation

extension NotebookTransfer {
    /// Writes into a new staged directory and publishes it only after every file succeeds.
    public static func export(snapshot: NotebookSnapshot, to directory: URL, format: NotebookExportFormat, cancelled: () -> Bool = { false }) throws -> URL {
        try NotebookValidation.validate(snapshot)
        func check() throws { if cancelled() { throw NotebookTransferError.cancelled } }
        try check()
        let fm = FileManager.default
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw NotebookTransferError.invalidSource }
        let stage = directory.appendingPathComponent(".workjournal-export-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? fm.removeItem(at: stage) } }
        var occupied: Set<String> = []
        func name(_ raw: String) -> String {
            let invalid = CharacterSet(charactersIn: "/\\:\0\n\r")
            let value = raw.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value == "." || value == ".." ? "Untitled" : String(value.prefix(100))
        }
        func unique(_ parent: String, _ base: String, suffix: String = "") -> String {
            var candidate = parent + base + suffix, count = 2
            while !occupied.insert(candidate.lowercased()).inserted { candidate = parent + base + " (\(count))" + suffix; count += 1 }
            return candidate
        }
        let folders = Dictionary(uniqueKeysWithValues: snapshot.folders.filter { $0.deletedAt == nil }.map { ($0.id, $0) })
        var folderPaths: [UUID: String] = [:]
        func path(_ id: UUID?) throws -> String {
            guard let id else { return "" }
            if let existing = folderPaths[id] { return existing }
            guard let folder = folders[id] else { throw NotebookTransferError.invalidSnapshot("目录不存在") }
            let parent = try path(folder.parentID)
            let value = unique(parent, name(folder.name)) + "/"
            folderPaths[id] = value
            try fm.createDirectory(at: stage.appendingPathComponent(value), withIntermediateDirectories: true)
            return value
        }
        for folder in snapshot.folders where folder.deletedAt == nil { _ = try path(folder.id) }
        let assets = Dictionary(grouping: snapshot.assets, by: \.ownerNoteID)
        var notePaths: [UUID: String] = [:]
        for note in snapshot.notes where note.deletedAt == nil { notePaths[note.id] = unique(try path(note.folderID), name(note.title), suffix: format == .markdown ? ".md" : ".html") }
        for note in snapshot.notes where note.deletedAt == nil {
            try check()
            guard let relative = notePaths[note.id] else { continue }
            let file = stage.appendingPathComponent(relative)
            let parentPath = String(relative.prefix(relative.count - file.lastPathComponent.count))
            var text = note.markdown
            var trustedRelativeLinks: Set<String> = []
            let owned = assets[note.id] ?? []
            var detached: [String] = []
            for item in owned {
                try check()
                let assetParent = parentPath + "assets/" + note.id.uuidString.lowercased() + "/"
                let assetPath = unique(assetParent, name(item.fileName))
                let url = stage.appendingPathComponent(assetPath)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try item.data.write(to: url, options: .atomic)
                let localPath = String(assetPath.dropFirst(parentPath.count))
                let escapedPath = localPath.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()#?"))) ?? localPath
                if !text.contains(item.reference) { detached.append("[\(NotebookHTML.escapeMarkdown(item.fileName))](\(escapedPath))") }
                text = text.replacingOccurrences(of: item.reference, with: escapedPath)
            }
            if !detached.isEmpty { text += "\n\n## 附件\n\n" + detached.joined(separator: "\n\n") }
            // Export explicit, reliable note links with paths relative to the document's folder.
            for (id, target) in notePaths {
                let fromComponents = parentPath.split(separator: "/").map(String.init)
                var toComponents = target.split(separator: "/").map(String.init)
                var common = 0
                while common < fromComponents.count && common < toComponents.count && fromComponents[common] == toComponents[common] { common += 1 }
                toComponents = Array(repeating: "..", count: fromComponents.count - common) + toComponents.dropFirst(common)
                let relativeLink = toComponents.joined(separator: "/").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
                trustedRelativeLinks.insert(relativeLink)
                text = text.replacingOccurrences(of: "workjournal-note://" + id.uuidString.lowercased(), with: relativeLink)
            }
            let output: String
            switch format {
            case .markdown: output = text
            case .html:
                output = """
                <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><title>\(NotebookHTML.escape(note.title))</title><style>body{max-width:900px;margin:40px auto;padding:0 24px;font:16px/1.7 system-ui,sans-serif;color:#222}img{max-width:100%;height:auto}pre{overflow:auto;background:#f4f4f4;padding:16px}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:6px 12px}blockquote{border-left:3px solid #ccc;padding-left:16px;color:#555}a{color:#245bb5}</style></head><body><h1>\(NotebookHTML.escape(note.title))</h1>\(try NotebookHTML.renderMarkdown(text, trustedRelativeLinks: trustedRelativeLinks))</body></html>
                """
            }
            try Data(output.utf8).write(to: file, options: .atomic)
        }
        try check()
        var target = directory.appendingPathComponent("WorkJournal Export", isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: target.path) { target = directory.appendingPathComponent("WorkJournal Export \(counter)", isDirectory: true); counter += 1 }
        try fm.moveItem(at: stage, to: target); published = true
        return target
    }
}

extension NotebookHTML {
    static func renderMarkdown(_ source: String, trustedRelativeLinks: Set<String> = []) throws -> String {
        let scan = try NotebookMarkdownReferences.scan(source)
        var markdown = source
        let edits = scan.referenceReplacements + scan.definitionRanges.map { ($0, "") }
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            if let range = Range(range, in: markdown) { markdown.replaceSubrange(range, with: replacement) }
        }
        func inline(_ original: String) throws -> String {
            // Code spans preserve backslashes verbatim and must be isolated before ordinary text escapes.
            let codePrefix = "WJCODE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            var codeTokens: [(String, String)] = [], prepared = original
            let codeRanges = try NotebookMarkdownReferences.scan(original).literalRanges
            for (index, codeRange) in codeRanges.enumerated().reversed() {
                guard let range = Range(codeRange, in: prepared), let sourceRange = Range(codeRange, in: original) else { continue }
                let source = String(original[sourceRange]), delimiter = source.prefix { $0 == "`" }.count
                guard delimiter > 0, source.count >= delimiter * 2 else { continue }
                var content = String(source.dropFirst(delimiter).dropLast(delimiter)).replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                if content.hasPrefix(" "), content.hasSuffix(" "), content.contains(where: { $0 != " " }) { content = String(content.dropFirst().dropLast()) }
                let token = codePrefix + "X" + String(index) + "X"
                codeTokens.append((token, "<code>" + escape(content) + "</code>")); prepared.replaceSubrange(range, with: token)
            }
            // Protect escaped punctuation before tokenization so literal stars/tags never become markup.
            let escapeRegex = try NSRegularExpression(pattern: ##"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])"##)
            let prefix = "WJESC" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            var escaped: [(String, String)] = [], raw = prepared
            for (index, match) in escapeRegex.matches(in: prepared, range: NSRange(prepared.startIndex..., in: prepared)).enumerated().reversed() {
                guard let range = Range(match.range, in: raw), let character = Range(match.range(at: 1), in: prepared) else { continue }
                let token = prefix + "X" + String(index) + "X"
                escaped.append((token, escape(String(prepared[character])))); raw.replaceSubrange(range, with: token)
            }
            var result = "", cursor = raw.startIndex
            let pattern = #"!?\[[^\]\n]*\]\([^\)\n]+\)|\*\*[^*\n]+\*\*|\*[^*\n]+\*|~~[^~\n]+~~|<[^>]+>"#
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let range = Range(match.range, in: raw) else { continue }
                result += escape(String(raw[cursor..<range.lowerBound]))
                let token = String(raw[range]); cursor = range.upperBound
                if token.hasPrefix("<") { result += token; continue }
                if token.hasPrefix("**") { result += "<strong>" + escape(String(token.dropFirst(2).dropLast(2))) + "</strong>"; continue }
                if token.hasPrefix("~~") { result += "<del>" + escape(String(token.dropFirst(2).dropLast(2))) + "</del>"; continue }
                if token.hasPrefix("*") { result += "<em>" + escape(String(token.dropFirst().dropLast())) + "</em>"; continue }
                if let middle = token.range(of: "]("), let begin = token.firstIndex(of: "[") {
                    let label = String(token[token.index(after: begin)..<middle.lowerBound])
                    let destination = String(token[middle.upperBound..<token.index(before: token.endIndex)]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    if safeLink(destination, allowRelative: true, trustedRelativeLinks: trustedRelativeLinks) {
                        result += token.hasPrefix("!") ? "<img src=\"\(escape(destination))\" alt=\"\(escape(label))\">" : "<a href=\"\(escape(destination))\">\(escape(label))</a>"
                    } else { result += escape(label) }
                }
            }
            result += escape(String(raw[cursor...]))
            for (token, literal) in escaped { result = result.replacingOccurrences(of: token, with: literal) }
            for (token, code) in codeTokens { result = result.replacingOccurrences(of: token, with: code) }
            return result
        }
        var languages: [String] = []
        var fence: Character?, fenceLength = 0
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let marker = line.first else { continue }
            let run = line.prefix { $0 == marker }.count
            if let current = fence {
                if marker == current && run >= fenceLength && line.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
            } else if (marker == "`" || marker == "~") && run >= 3 {
                fence = marker; fenceLength = run
                languages.append(String(line.dropFirst(run).prefix { !$0.isWhitespace }).filter { $0.isLetter || $0.isNumber || ["-", "+", "#"].contains($0) })
            }
        }
        var codeIndex = 0
        var blocks: [String] = []
        for block in MarkdownBlocks.parse(markdown) {
            switch block {
            case let .heading(level, value): blocks.append("<h\(level)>\(try inline(value))</h\(level)>")
            case let .paragraph(value):
                let content = try inline(value).replacingOccurrences(of: "\n", with: "<br>")
                blocks.append(value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") ? content : "<p>\(content)</p>")
            case let .quote(value): blocks.append("<blockquote>\(try inline(value))</blockquote>")
            case let .item(marker, value):
                let tag = marker == "•" ? "ul" : "ol"
                var text = value
                if value.hasPrefix("[x] ") || value.hasPrefix("[X] ") { text = "☑ " + String(value.dropFirst(4)) }
                else if value.hasPrefix("[ ] ") { text = "☐ " + String(value.dropFirst(4)) }
                blocks.append("<\(tag)><li>\(try inline(text))</li></\(tag)>")
            case let .code(value):
                let language = codeIndex < languages.count ? languages[codeIndex] : ""; codeIndex += 1
                blocks.append("<pre><code" + (language.isEmpty ? "" : " class=\"language-\(escape(language))\"") + ">\(escape(value))</code></pre>")
            case .divider: blocks.append("<hr>")
            case let .table(table):
                var html = "<table><thead><tr>"
                for header in table.headers { html += "<th>\(try inline(header))</th>" }
                html += "</tr></thead><tbody>"
                for row in table.rows { html += "<tr>"; for cell in row { html += "<td>\(try inline(cell))</td>" }; html += "</tr>" }
                blocks.append(html + "</tbody></table>")
            }
        }
        return try sanitize(blocks.joined(separator: "\n"), trustedRelativeLinks: trustedRelativeLinks)
    }
}
