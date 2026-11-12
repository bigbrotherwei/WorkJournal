import Foundation

/// Only identifies Markdown destinations; it never opens files or interprets embedded HTML.
/// UTF-16 offsets keep edits lossless around Unicode text and let all edits use the original source.
enum NotebookMarkdownReferences {
    struct Destination { var range: NSRange; var value: String; var isImage: Bool }
    struct Scan { var destinations: [Destination]; var literalRanges: [NSRange]; var missingLabels: [String]; var referenceReplacements: [(NSRange, String)]; var definitionRanges: [NSRange] }
    static func unescape(_ value: String) -> String {
        let values = Array(value); var result = "", index = 0
        while index < values.count {
            if values[index] == "\\", index + 1 < values.count, values[index + 1].isWhitespace || NotebookHTML.markdownPunctuation.contains(values[index + 1]) { index += 1 }
            result.append(values[index]); index += 1
        }
        return result
    }
    static func scan(_ raw: String) throws -> Scan {
        let text = raw as NSString, characters = Array(raw.utf16), count = characters.count
        var literalRanges: [NSRange] = []
        var fenceStart: Int?, marker: Character?, fenceLength = 0
        raw.enumerateSubstrings(in: raw.startIndex..., options: .byLines) { line, lineRange, enclosingRange, _ in
            let line = (line ?? "").trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { return }
            let run = line.prefix { $0 == first }.count, start = NSRange(lineRange, in: raw).location
            if let current = marker {
                if first == current && run >= fenceLength && line.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    let whole = NSRange(enclosingRange, in: raw)
                    literalRanges.append(NSRange(location: fenceStart!, length: whole.location + whole.length - fenceStart!)); marker = nil; fenceStart = nil
                }
            } else if (first == "`" || first == "~") && run >= 3 { marker = first; fenceLength = run; fenceStart = start }
        }
        if let start = fenceStart { literalRanges.append(NSRange(location: start, length: count - start)) }
        func literal(_ range: NSRange) -> Bool { literalRanges.contains { NSIntersectionRange($0, range).length > 0 } }
        let runs = try NSRegularExpression(pattern: "`+").matches(in: raw, range: NSRange(location: 0, length: count)).map(\.range)
        func escapedOpening(_ position: Int) -> Bool {
            var cursor = position, backslashes = 0
            while cursor > 0, characters[cursor - 1] == 92 { backslashes += 1; cursor -= 1 }
            return backslashes % 2 == 1
        }
        var runIndex = 0
        while runIndex < runs.count {
            let start = runs[runIndex]
            // Backslashes escape an opening delimiter only in ordinary text. Inside an
            // established code span they are literal, including immediately before its closer.
            if literal(start) || escapedOpening(start.location) { runIndex += 1; continue }
            if let endIndex = runs.indices.dropFirst(runIndex + 1).first(where: { runs[$0].length == start.length && !literal(runs[$0]) }) {
                literalRanges.append(NSRange(location: start.location, length: NSMaxRange(runs[endIndex]) - start.location)); runIndex = endIndex + 1
            } else { runIndex += 1 }
        }
        func bracket(_ start: Int) -> Int? {
            guard start < count, characters[start] == 91 else { return nil }
            var depth = 1, cursor = start + 1
            while cursor < count {
                if characters[cursor] == 92 { cursor += 2; continue }
                if characters[cursor] == 91 { depth += 1 }
                if characters[cursor] == 93 { depth -= 1; if depth == 0 { return cursor } }
                if characters[cursor] == 10 || characters[cursor] == 13 { return nil }
                cursor += 1
            }
            return nil
        }
        func normalize(_ value: String) -> String { unescape(value).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
        // A destination is either angle-delimited (spaces allowed) or a balanced parenthesis token.
        func destination(_ start: Int, limit: Int) -> (range: NSRange, end: Int)? {
            guard start < limit else { return nil }
            if characters[start] == 60 {
                var cursor = start + 1
                while cursor < limit {
                    if characters[cursor] == 92 { cursor += 2; continue }
                    if characters[cursor] == 62 { return (NSRange(location: start + 1, length: cursor - start - 1), cursor + 1) }
                    if characters[cursor] == 10 || characters[cursor] == 13 { return nil }; cursor += 1
                }
                return nil
            }
            var cursor = start, depth = 0
            while cursor < limit {
                let current = characters[cursor]
                if current == 92, cursor + 1 < limit { cursor += 2; continue }
                if current == 32 || current == 9 || current == 10 || current == 13 { break }
                if current == 40 { depth += 1 }
                if current == 41 { if depth == 0 { break }; depth -= 1 }
                cursor += 1
            }
            guard cursor > start, depth == 0 else { return nil }
            return (NSRange(location: start, length: cursor - start), cursor)
        }
        var definitions: [String: NSRange] = [:], definitionLines: [NSRange] = []
        raw.enumerateSubstrings(in: raw.startIndex..., options: .byLines) { _, lineRange, _, _ in
            let range = NSRange(lineRange, in: raw)
            guard !literal(range) else { return }
            var cursor = range.location, indentation = 0
            while cursor < NSMaxRange(range), characters[cursor] == 32 { cursor += 1; indentation += 1 }
            guard indentation <= 3, let close = bracket(cursor), close + 1 < NSMaxRange(range), characters[close + 1] == 58 else { return }
            let label = normalize(text.substring(with: NSRange(location: cursor + 1, length: close - cursor - 1)))
            cursor = close + 2
            while cursor < NSMaxRange(range), characters[cursor] == 32 || characters[cursor] == 9 { cursor += 1 }
            if let value = destination(cursor, limit: NSMaxRange(range)), !label.isEmpty {
                if definitions[label] == nil { definitions[label] = value.range }
                definitionLines.append(range)
            }
        }
        var found: [Int: Destination] = [:], missing: [String] = [], cursor = 0
        var referenceReplacements: [(NSRange, String)] = []
        while cursor < count {
            if literal(NSRange(location: cursor, length: 1)) || definitionLines.contains(where: { NSLocationInRange(cursor, $0) }) { cursor += 1; continue }
            if characters[cursor] == 92 { cursor += 2; continue }
            let isImage = characters[cursor] == 33 && cursor + 1 < count && characters[cursor + 1] == 91
            let open = isImage ? cursor + 1 : cursor
            guard characters[open] == 91, let close = bracket(open) else { cursor += 1; continue }
            let label = text.substring(with: NSRange(location: open + 1, length: close - open - 1))
            let after = close + 1
            if after < count, characters[after] == 40 {
                var start = after + 1
                while start < count, characters[start] == 32 || characters[start] == 9 { start += 1 }
                if let value = destination(start, limit: count) {
                    var end = value.end
                    while end < count, characters[end] == 32 || characters[end] == 9 { end += 1 }
                    // Optional title is kept byte-for-byte, outside the replaced destination.
                    if end < count, characters[end] == 34 || characters[end] == 39 {
                        let quote = characters[end]; end += 1
                        while end < count, characters[end] != quote { end += characters[end] == 92 ? 2 : 1 }; end += 1
                        while end < count, characters[end] == 32 || characters[end] == 9 { end += 1 }
                    }
                    if end < count, characters[end] == 41 {
                        found[value.range.location] = Destination(range: value.range, value: unescape(text.substring(with: value.range)), isImage: isImage); cursor = end + 1; continue
                    }
                }
            } else {
                var reference = label, explicit = false, end = after
                if after < count, characters[after] == 91, let referenceClose = bracket(after) {
                    reference = text.substring(with: NSRange(location: after + 1, length: referenceClose - after - 1)); if reference.isEmpty { reference = label }
                    explicit = true; end = referenceClose + 1
                }
                if let range = definitions[normalize(reference)] {
                    if let previous = found[range.location] { found[range.location]?.isImage = previous.isImage && isImage }
                    else { found[range.location] = Destination(range: range, value: unescape(text.substring(with: range)), isImage: isImage) }
                    let destination = text.substring(with: range)
                    referenceReplacements.append((NSRange(location: cursor, length: end - cursor), (isImage ? "!" : "") + "[" + label + "](<" + destination + ">)"))
                    cursor = end; continue
                } else if explicit { missing.append(reference); cursor = end; continue }
            }
            cursor = after
        }
        return Scan(destinations: found.values.sorted { $0.range.location < $1.range.location }, literalRanges: literalRanges, missingLabels: missing, referenceReplacements: referenceReplacements, definitionRanges: definitionLines)
    }
}
