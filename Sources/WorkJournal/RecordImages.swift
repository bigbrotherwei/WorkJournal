import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import JournalCore

@MainActor enum ImageImport {
    static func fromFile(_ url: URL) throws -> ImageAttachment {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw JournalError.invalid("原图片超过20 MB，请先缩小后再添加。") }
        return try normalized(Data(contentsOf: url), name: url.lastPathComponent)
    }
    static func pasted() throws -> ImageAttachment {
        let board = NSPasteboard.general
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            return try normalized(data, name: "剪贴板图片")
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
            return try fromFile(url)
        }
        throw JournalError.invalid("剪贴板里没有图片。请先复制图片，或使用“添加图片”。")
    }
    static func normalized(_ data: Data, name: String) throws -> ImageAttachment {
        guard data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30_000, height <= 30_000,
              Double(width) * Double(height) <= 100_000_000 else {
            throw JournalError.invalid("无法读取这张图片，或图片过大。支持常见静态图片，原文件上限20 MB。")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw JournalError.invalid("图片解码失败。")
        }
        let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, (alpha ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil) else {
            throw JournalError.invalid("无法处理图片。")
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw JournalError.invalid("无法保存图片副本。") }
        let image = ImageAttachment(name: name, data: output as Data)
        try ImageAttachment.validate([image])
        return image
    }
}
