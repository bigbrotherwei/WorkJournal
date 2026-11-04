import Foundation

public enum RecordContent {
    public enum Part: Equatable { case text(String), image(UUID) }
    public static func marker(_ id: UUID) -> String { "![图片](attachment://\(id.uuidString))" }
    public static func parts(_ text: String) -> [Part] {
        let regex = try! NSRegularExpression(pattern: #"!\[图片\]\(attachment://([0-9A-Fa-f-]{36})\)"#)
        let source = text as NSString
        var result: [Part] = [], offset = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let id = UUID(uuidString: source.substring(with: match.range(at: 1))) else { continue }
            if match.range.location > offset { result.append(.text(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))) }
            result.append(.image(id)); offset = NSMaxRange(match.range)
        }
        if offset < source.length { result.append(.text(source.substring(from: offset))) }
        return result
    }
    public static func validate(text: String, images: [ImageAttachment]) throws {
        try ImageAttachment.validate(images)
        for part in parts(text) {
            if case .image(let id) = part, !images.contains(where: { $0.id == id }) {
                throw JournalError.invalid("记录中的图片缺失，未保存；请重新插入图片。")
            }
        }
    }
    public static func plainText(_ text: String) -> String {
        parts(text).map { if case .text(let value) = $0 { return value }; return "\n" }.joined()
    }
}

public struct RecordDraft: Codable, Equatable {
    public var text: String
    public var images: [ImageAttachment]
    public init(text: String = "", images: [ImageAttachment] = []) { self.text = text; self.images = images }
}
