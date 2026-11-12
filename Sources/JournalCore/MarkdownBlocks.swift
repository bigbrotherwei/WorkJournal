import Foundation

/// Common report blocks; inline styling is handled by the native Markdown parser.
public enum MarkdownBlocks {
    public enum Alignment: Equatable, Sendable { case left, center, right }
    public struct Table: Equatable, Sendable {
        public let headers: [String]
        public let alignments: [Alignment]
        public let rows: [[String]]
    }
    public enum Block: Equatable, Sendable {
        case table(Table)
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
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
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
            if index < lines.count, let headers = cells(line), let markers = cells(lines[index]),
               headers.count == markers.count, let alignments = alignments(markers) {
                let first = index - 1
                index += 1
                var rows: [[String]] = []
                var overflow = false
                while index < lines.count, let row = cells(lines[index]) {
                    if row.count > headers.count { overflow = true }
                    rows.append(row + Array(repeating: "", count: max(0, headers.count - row.count)))
                    index += 1
                }
                flush()
                // Never discard excess cells: unsupported tables retain their complete source.
                if overflow { result.append(.paragraph(lines[first..<index].joined(separator: "\n"))) }
                else { result.append(.table(Table(headers: headers, alignments: alignments, rows: rows))) }
                continue
            }
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

    private static func alignments(_ markers: [String]) -> [Alignment]? {
        var values: [Alignment] = []
        for marker in markers {
            var middle = marker[...]
            if middle.first == ":" { middle = middle.dropFirst() }
            if middle.last == ":" { middle = middle.dropLast() }
            guard middle.count >= 3, middle.allSatisfy({ $0 == "-" }) else { return nil }
            values.append(marker.hasSuffix(":") ? (marker.hasPrefix(":") ? .center : .right) : .left)
        }
        return values
    }
    /// Split only unescaped pipes outside matched code spans; preserve inline Markdown verbatim.
    private static func cells(_ raw: String) -> [String]? {
        let chars = Array(raw.trimmingCharacters(in: .whitespaces))
        var cells: [String] = [], cell = "", index = 0, codeTicks = 0, separators = 0
        func closingTicks(after start: Int, count: Int) -> Bool {
            var cursor = start
            while cursor < chars.count {
                if chars[cursor] == "`" {
                    var end = cursor
                    while end < chars.count && chars[end] == "`" { end += 1 }
                    if end - cursor == count { return true }
                    cursor = end
                } else { cursor += 1 }
            }
            return false
        }
        while index < chars.count {
            let char = chars[index]
            if char == "\\", codeTicks == 0, index + 1 < chars.count {
                cell.append(char); cell.append(chars[index + 1]); index += 2; continue
            }
            if char == "`" {
                var end = index
                while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - index
                if codeTicks == count { codeTicks = 0 }
                else if codeTicks == 0 && closingTicks(after: end, count: count) { codeTicks = count }
                cell += String(chars[index..<end]); index = end; continue
            }
            if char == "|", codeTicks == 0 { cells.append(cell); cell = ""; separators += 1 }
            else { cell.append(char) }
            index += 1
        }
        guard separators > 0 else { return nil }
        cells.append(cell)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        guard !cells.isEmpty else { return nil }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
