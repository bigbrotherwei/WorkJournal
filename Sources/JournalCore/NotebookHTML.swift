import Foundation
import SwiftSoup

/// A structural HTML reader. It never fetches URLs or evaluates scripts/styles.
enum NotebookHTML {
    struct Result { var markdown: String; var warnings: [String]; var requiresOriginal: Bool }
    static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    static let markdownPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
    static func escapeMarkdown(_ text: String) -> String {
        text.map { markdownPunctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
    static func safeLink(_ value: String, allowRelative: Bool = false, trustedRelativeLinks: Set<String> = []) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return false }
        if value.hasPrefix("#") { return true }
        if let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased() {
            if scheme == "workjournal-note" {
                return parts.host.flatMap(UUID.init(uuidString:)) != nil && parts.path.isEmpty && parts.user == nil && parts.password == nil && parts.port == nil && parts.query == nil && parts.fragment == nil
            }
            return ["https", "http", "mailto", "evernote", "workjournal-asset"].contains(scheme)
        }
        guard allowRelative, !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.contains("\\") else { return false }
        // Only the exporter may authorize an exact parent path that it generated from validated note identities.
        return trustedRelativeLinks.contains(value) || !(value.removingPercentEncoding ?? value).split(separator: "/").contains("..")
    }
    static func controlledStyle(_ raw: String) -> String {
        var output: [String] = []
        for declaration in raw.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard pair.count == 2 else { continue }
            let key = pair[0], value = pair[1]
            let valid: Bool
            switch key {
            case "color", "background-color": valid = value.range(of: #"^(#[0-9a-f]{3,8}|[a-z]{1,20}|rgba?\([0-9.,% ]+\)|hsla?\([0-9.,% ]+\))$"#, options: .regularExpression) != nil
            case "text-align": valid = ["left", "right", "center", "justify", "start", "end"].contains(value)
            case "text-decoration": valid = ["underline", "line-through", "underline line-through", "none"].contains(value)
            case "font-weight": valid = ["bold", "normal", "400", "600", "700", "800", "900"].contains(value)
            case "font-style": valid = ["italic", "normal"].contains(value)
            case "vertical-align": valid = ["sub", "super", "baseline"].contains(value)
            default: valid = false
            }
            if valid { output.append("\(key): \(value)") }
        }
        return output.joined(separator: "; ")
    }
    static func importHTML(_ html: String, resource: (String) throws -> String?, media: [String: String] = [:], noteLink: (String) -> String? = { _ in nil }) throws -> Result {
        let document = try SwiftSoup.parse(html)
        var warnings: [String] = []
        var requiresOriginal = false
        func children(_ node: Node, depth: Int) throws -> String {
            guard depth <= 128 else { throw NotebookTransferError.limitExceeded("HTML 结构深度") }
            return try node.getChildNodes().map { try convert($0, depth: depth + 1) }.joined()
        }
        func convert(_ node: Node, depth: Int) throws -> String {
            if let text = node as? TextNode { return escapeMarkdown(text.getWholeText()) }
            guard let element = node as? Element else { return "" }
            let tag = element.tagName().lowercased()
            if ["script", "style", "iframe", "object", "embed", "base", "link", "meta", "form", "input", "button", "svg", "math", "noscript"].contains(tag) {
                warnings.append("不安全或不支持的 HTML 结构已移除：\(tag)。")
                requiresOriginal = true; return ""
            }
            if tag == "en-crypt" { requiresOriginal = true; warnings.append("加密块无法解密；已保留原文。"); return "\n\n> 加密内容保留在原文件中，尚未转换。\n\n" }
            if tag == "en-todo" { return "\n- [\((try element.attr("checked")).lowercased() == "true" ? "x" : " ")] " }
            if tag == "en-media" {
                let hash = try element.attr("hash").lowercased()
                guard let reference = media[hash] else { requiresOriginal = true; warnings.append("ENEX 资源 MD5 无法匹配，原始内容已保留。"); return "[缺失附件]" }
                return ((try element.attr("type")).hasPrefix("image/") ? "!" : "") + "[附件](\(reference))"
            }
            if tag == "img" {
                let value = try element.attr("src"), alt = escapeMarkdown(try element.attr("alt"))
                if let local = try resource(value) { return "![\(alt)](\(local))" }
                if safeLink(value), value.hasPrefix("http") { warnings.append("外部图片仅保留链接；未联网下载。"); return "[外部图片\(alt.isEmpty ? "" : ": " + alt)](\(value))" }
                warnings.append("无法解析或不安全的图片已保留为占位提示。"); return "[缺失图片：\(alt)]"
            }
            let content = try children(node, depth: depth)
            let style = controlledStyle(try element.attr("style"))
            func styled(_ text: String, tag: String = "span") -> String { style.isEmpty ? text : "<\(tag) style=\"\(escape(style))\">\(text)</\(tag)>" }
            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6": return "\n\n" + String(repeating: "#", count: Int(tag.dropFirst()) ?? 1) + " " + styled(content) + "\n\n"
            case "p", "div", "section", "article": return "\n\n" + styled(content, tag: "div") + "\n\n"
            case "br": return "\n"
            case "hr": return "\n\n---\n\n"
            case "strong", "b": return "**\(content)**"
            case "em", "i": return "*\(content)*"
            case "s", "strike", "del": return "~~\(content)~~"
            case "u", "sub", "sup": return "<\(tag)>\(content)</\(tag)>"
            case "span", "font", "mark":
                var safe = style
                if tag == "font" { let color = controlledStyle("color: \(try element.attr("color"))"); if !color.isEmpty { safe += (safe.isEmpty ? "" : "; ") + color } }
                if tag == "mark" && safe.isEmpty { safe = "background-color: yellow" }
                return safe.isEmpty ? content : "<span style=\"\(escape(safe))\">\(content)</span>"
            case "blockquote": return "\n\n" + content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            case "li":
                let marker = element.parent()?.tagName() == "ol" ? "1. " : "- "
                return "\n" + marker + content.trimmingCharacters(in: .whitespacesAndNewlines)
            case "ul", "ol": return "\n" + content + "\n\n"
            case "pre":
                let code = try element.select("code").first()
                let classes = try code?.className() ?? ""
                let language = classes.split(separator: " ").first(where: { $0.hasPrefix("language-") }).map { String($0.dropFirst(9)).filter { $0.isLetter || $0.isNumber || ["+", "-", "#"].contains($0) } } ?? ""
                let text = try (code ?? element).text(trimAndNormaliseWhitespace: false)
                let fence = text.contains("```") ? "````" : "```"
                return "\n\n\(fence)\(language)\n\(text)\n\(fence)\n\n"
            case "code":
                let text = try element.text(trimAndNormaliseWhitespace: false)
                let runs = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: runs + 1)
                return fence + (text.hasPrefix("`") || text.hasSuffix("`") ? " " + text + " " : text) + fence
            case "a":
                let href = try element.attr("href")
                if let mapped = noteLink(href) { return "[\(content)](\(mapped))" }
                if safeLink(href) { return "[\(content)](\(href))" }
                if let local = try resource(href) { return "[\(content)](\(local))" }
                warnings.append("不安全或未解析的链接已移除。"); return content
            case "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption":
                var attributes = style.isEmpty ? "" : " style=\"\(escape(style))\""
                for attribute in ["colspan", "rowspan"] where ["td", "th"].contains(tag) {
                    if let count = Int(try element.attr(attribute)), (1...100).contains(count) { attributes += " \(attribute)=\"\(count)\"" }
                }
                let result = "<\(tag)\(attributes)>\(content)</\(tag)>"
                return tag == "table" ? "\n\n" + result + "\n\n" : result
            default:
                if tag.hasPrefix("en-") && tag != "en-note" { requiresOriginal = true; warnings.append("不支持的专有结构已保留在原文件：\(tag)。") }
                return content
            }
        }
        let text = try children(document.body() ?? document, depth: 0)
        return Result(markdown: text.trimmingCharacters(in: .whitespacesAndNewlines), warnings: Array(Set(warnings)).sorted(), requiresOriginal: requiresOriginal)
    }

    /// Rebuild only approved HTML nodes/attributes; output is safe to embed in exported documents.
    static func sanitize(_ html: String, trustedRelativeLinks: Set<String> = []) throws -> String {
        let document = try SwiftSoup.parseBodyFragment(html)
        let allowed = Set(["p", "div", "span", "strong", "b", "em", "i", "s", "del", "u", "sub", "sup", "mark", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code", "ul", "ol", "li", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "br", "hr", "a", "img"])
        func render(_ node: Node, depth: Int) throws -> String {
            guard depth < 128 else { throw NotebookTransferError.limitExceeded("HTML 结构深度") }
            if let text = node as? TextNode { return escape(text.getWholeText()) }
            guard let element = node as? Element else { return "" }
            let tag = element.tagName().lowercased()
            if ["script", "style", "iframe", "object", "embed", "svg", "math"].contains(tag) { return "" }
            let children = try node.getChildNodes().map { try render($0, depth: depth + 1) }.joined()
            guard allowed.contains(tag) else { return children }
            var attributes = ""
            let style = controlledStyle(try element.attr("style"))
            if !style.isEmpty { attributes += " style=\"\(escape(style))\"" }
            for attribute in ["colspan", "rowspan"] where ["td", "th"].contains(tag) { if let number = Int(try element.attr(attribute)), (1...100).contains(number) { attributes += " \(attribute)=\"\(number)\"" } }
            if tag == "code" {
                let language = try element.className().split(separator: " ").first(where: { $0.hasPrefix("language-") })
                if let language, language.allSatisfy({ $0.isLetter || $0.isNumber || ["-", "+", "#"].contains($0) }) { attributes += " class=\"\(escape(String(language)))\"" }
            }
            if tag == "a" { let href = try element.attr("href"); if safeLink(href, allowRelative: true, trustedRelativeLinks: trustedRelativeLinks) { attributes += " href=\"\(escape(href))\"" } }
            if tag == "img" {
                let src = try element.attr("src")
                guard safeLink(src, allowRelative: true), URL(string: src)?.scheme == nil else { return "<span>[外部或无效图片]</span>" }
                attributes += " src=\"\(escape(src))\" alt=\"\(escape(try element.attr("alt")))\""
            }
            if ["br", "hr", "img"].contains(tag) { return "<\(tag)\(attributes)>" }
            return "<\(tag)\(attributes)>\(children)</\(tag)>"
        }
        return try (document.body()?.getChildNodes() ?? []).map { try render($0, depth: 0) }.joined()
    }
}
