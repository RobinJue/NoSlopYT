import Foundation

/// Parses the `suggestqueries.google.com` Firefox-format response (`["q",["s1","s2",...],...]`).
///
/// The `client=youtube` flavour (`window.google.ac.h(["q",[["s1",0,[512]],...],{}])`) is understood too, in case the
/// endpoint ever changes. Anything else gives no suggestions.
public enum SuggestionsParser {
    public static func parse(_ data: Data) -> [String] {
        guard let list = document(from: data)?[1]?.array else { return [] }
        var seen = Set<String>()
        var suggestions: [String] = []
        for item in list {
            // Firefox: a plain string. JSONP: an array whose first element is the string.
            guard let raw = item.string ?? item[0]?.string else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, seen.insert(text).inserted {
                suggestions.append(text)
            }
        }
        return suggestions
    }

    private static func document(from data: Data) -> JSON? {
        if let json = try? JSON(data: data) { return json }
        // JSONP: take what is between the first "(" and the last ")".
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        return try? JSON(data: Data(text[text.index(after: open)..<close].utf8))
    }
}
