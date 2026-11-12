import Foundation

public enum NotebookListPreview {
    private static let sourceScalarLimit = 1_024
    private static let characterLimit = 240

    /// A small list excerpt, independent of the size of an imported document.
    public static func text(_ markdown: String) -> String {
        let scalars = Array(markdown.unicodeScalars.prefix(sourceScalarLimit + 1))
        let sourceWasTruncated = scalars.count > sourceScalarLimit
        var excerpt = String(String.UnicodeScalarView(scalars.prefix(sourceScalarLimit)))
        if sourceWasTruncated {
            // The scalar boundary may split an emoji or combining sequence.
            // Drop the final grapheme without looking farther into the source.
            excerpt.removeLast()
        }

        var plain = ""
        var needsSpace = false
        for scalar in excerpt.unicodeScalars {
            switch scalar {
            case "#", "*", "[", "]", "<", ">": continue
            default: break
            }
            if scalar.properties.isWhitespace {
                needsSpace = !plain.isEmpty
            } else {
                if needsSpace { plain.append(" "); needsSpace = false }
                plain.unicodeScalars.append(scalar)
            }
        }

        let characters = Array(plain.prefix(characterLimit + 1))
        if sourceWasTruncated || characters.count > characterLimit {
            return String(characters.prefix(characterLimit - 1))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return plain
    }
}
