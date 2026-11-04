import Foundation

/// Common report blocks; inline styling is handled by the native Markdown parser.
public enum MarkdownBlocks {
    public enum Block: Equatable, Sendable {
        case heading(Int, String), paragraph(String), item(String, String), quote(String), code(String), divider
    }
    public static func parse(_ source: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: Character?
        var fenceLength = 0
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                let run = line.prefix { $0 == marker }
                if run.count >= fenceLength && line.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(.code(code.joined(separator: "\n"))); code = []; fence = nil
                } else { code.append(raw) }
                continue
            }
            if let first = line.first, first == "`" || first == "~" {
                let run = line.prefix { $0 == first }
                if run.count >= 3 { flush(); fence = first; fenceLength = run.count; continue }
            }
            if line.isEmpty { flush(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush(); result.append(.heading(hashes, String(line.dropFirst(hashes + 1)))); continue
            }
            let compact = line.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3 && ["-", "*", "_"].contains(String(compact.first!)) && Set(compact).count == 1 {
                flush(); result.append(.divider); continue
            }
            if line.hasPrefix("> ") || line == ">" {
                flush(); result.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); result.append(.item("•", String(line.dropFirst(2)))); continue
            }
            let digits = line.prefix { $0.isNumber }
            if !digits.isEmpty {
                let tail = line.dropFirst(digits.count)
                if tail.hasPrefix(". ") || tail.hasPrefix(") ") {
                    flush(); result.append(.item(String(digits) + ".", String(tail.dropFirst(2)))); continue
                }
            }
            paragraph.append(raw)
        }
        flush()
        if fence != nil { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }
}
