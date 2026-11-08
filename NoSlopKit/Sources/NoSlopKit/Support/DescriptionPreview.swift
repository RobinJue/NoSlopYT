import Foundation

/// The collapsed description on the watch page.
///
/// YouTube shortens the web addresses in a description ("https://studio.blender.org/projects/b...") and ends a cut-off
/// short description in "..." or "…". The collapsed card shows the text with a line limit, and a text that the limit
/// cuts adds an ellipsis of its own: "projects/b......". The preview drops YouTube's ellipsis where the line limit would
/// put its own.
public enum DescriptionPreview {
    /// `text` without the ellipsis ("..." or more dots, or "…") that ends the text, and without the one that ends a
    /// shortened web address at the end of a line (the last word of the line has a "/" in it), together with the white
    /// space before an ellipsis at the very end. Everything else, including a "..." inside a sentence, stays.
    public static func collapsedText(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "." || character == "…" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            var end = index
            var dots = 0
            while end < text.endIndex, text[end] == "." || text[end] == "…" {
                dots += text[end] == "…" ? 3 : 1
                end = text.index(after: end)
            }
            let atEnd = end == text.endIndex || text[end...].allSatisfy(\.isWhitespace)
            let atLineEnd = end == text.endIndex || text[end].isNewline
            let word = result.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            let endsAddress = !result.isEmpty && !(result.last?.isWhitespace ?? true) && word.contains("/")
            if dots >= 3, atEnd || (atLineEnd && endsAddress) {
                if atEnd {
                    while let last = result.last, last.isWhitespace { result.removeLast() }
                    return result
                }
            } else {
                result.append(contentsOf: text[index..<end])
            }
            index = end
        }
        return result
    }
}
