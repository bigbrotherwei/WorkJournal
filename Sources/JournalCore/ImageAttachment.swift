import Foundation
import ImageIO

public struct ImageAttachment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var data: Data
    public init(id: UUID = UUID(), name: String, data: Data) {
        self.id = id; self.name = name; self.data = data
    }
    public static let maxCount = 4
    public static let maxBytes = 2_000_000
    public static func validate(_ images: [ImageAttachment]) throws {
        guard images.count <= maxCount, Set(images.map(\.id)).count == images.count else {
            throw JournalError.invalid("每条记录最多添加4张图片，图片标识不能重复。")
        }
        for image in images {
            guard image.data.count <= maxBytes, !image.name.isEmpty,
                  let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 2048, height <= 2048,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw JournalError.invalid("图片无效或过大：每张保存后须不超过2 MB、最长边2048像素。")
            }
        }
    }
}
