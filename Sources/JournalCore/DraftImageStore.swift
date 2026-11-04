import Foundation

public struct DraftImageStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> RecordDraft? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 12_000_000 else { throw JournalError.invalid("图片草稿文件过大，未加载；原文件已保留。") }
        let images = try JSONDecoder().decode(RecordDraft.self, from: Data(contentsOf: url))
        try RecordContent.validate(text: images.text, images: images.images)
        return images
    }
    public func save(_ images: RecordDraft) throws {
        try RecordContent.validate(text: images.text, images: images.images)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(images).write(to: url, options: .atomic)
    }
}
