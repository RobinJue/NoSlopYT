import Foundation

/// Helpers for the text, image and number shapes InnerTube uses everywhere.
public enum InnerTubeText {
    // MARK: Text

    /// The plain text of a text node, trying in order: the node itself when it is a string, `simpleText`,
    /// `runs[].text` joined, then `content`. Returns nil when nothing non-empty is found.
    public static func text(_ node: JSON?) -> String? {
        guard let node else { return nil }
        if let string = node.string {
            return string.isEmpty ? nil : string
        }
        if let simple = node["simpleText"]?.string, !simple.isEmpty {
            return simple
        }
        if let runs = node["runs"]?.array {
            let joined = runs.compactMap { $0["text"]?.string }.joined()
            if !joined.isEmpty { return joined }
        }
        if let content = node["content"]?.string, !content.isEmpty {
            return content
        }
        return nil
    }

    // MARK: Images

    /// The renditions in `node.thumbnails[]` or `node.sources[]` (a bare array also works), sorted by ascending
    /// width. Protocol-relative URLs ("//host/path") get an `https:` scheme; entries without a usable URL are dropped.
    public static func thumbnails(_ node: JSON?) -> [Thumbnail] {
        guard let node else { return [] }
        guard let list = node["thumbnails"]?.array ?? node["sources"]?.array ?? node.array else { return [] }

        var found: [(index: Int, thumbnail: Thumbnail)] = []
        for (index, item) in list.enumerated() {
            guard var urlString = item["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !urlString.isEmpty else { continue }
            if urlString.hasPrefix("//") { urlString = "https:" + urlString }
            guard let url = URL(string: urlString) else { continue }
            found.append((index, Thumbnail(url: url, width: item["width"]?.int, height: item["height"]?.int)))
        }
        // Ascending width; equal (or missing) widths keep their original order.
        found.sort { lhs, rhs in
            let l = lhs.thumbnail.width ?? 0
            let r = rhs.thumbnail.width ?? 0
            return l != r ? l < r : lhs.index < rhs.index
        }
        return found.map(\.thumbnail)
    }

    // MARK: Counts

    /// Parses YouTube's count strings:
    /// "2,763,792 views" → 2763792, "810K views" → 810000, "1.25M subscribers" → 1250000, "1.5K videos" → 1500,
    /// "3B" → 3000000000, "No views" → 0. Text without a number ("watching") and nil give nil.
    public static func parseCount(_ text: String?) -> Int? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let characters = Array(trimmed)

        guard let first = characters.firstIndex(where: \.isASCIIDigit) else {
            // "No views", "No subscribers": an explicit zero. Anything else without digits has no count.
            return trimmed.lowercased().hasPrefix("no ") ? 0 : nil
        }

        var index = first
        var token = ""
        while index < characters.count, characters[index].isASCIIDigit || characters[index] == "," || characters[index] == "." {
            token.append(characters[index])
            index += 1
        }
        // Trailing punctuation belongs to the sentence, not the number.
        while let last = token.last, last == "," || last == "." {
            token.removeLast()
        }

        // An optional magnitude suffix right after the number (a plain or no-break space is tolerated).
        var cursor = index
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\u{00A0}" || characters[cursor] == "\u{202F}" {
            cursor += 1
        }
        var multiplier = 1.0
        var hasSuffix = false
        if cursor < characters.count {
            let isWordEnd = cursor + 1 >= characters.count || !characters[cursor + 1].isLetter
            if isWordEnd {
                switch characters[cursor] {
                case "K", "k": multiplier = 1_000; hasSuffix = true
                case "M", "m": multiplier = 1_000_000; hasSuffix = true
                case "B", "b": multiplier = 1_000_000_000; hasSuffix = true
                default: break
                }
            }
        }

        guard let value = decimalValue(of: token, hasSuffix: hasSuffix) else { return nil }
        return Int(exactly: (value * multiplier).rounded())
    }

    /// "1.25" and "1,25" are decimals when a magnitude suffix follows; without one, "," and "." group thousands
    /// ("2,763,792" or "2.763.792"). Anything that fits neither reading has no count.
    private static func decimalValue(of token: String, hasSuffix: Bool) -> Double? {
        let separators = token.filter { $0 == "," || $0 == "." }.count
        if separators == 0 { return Double(token) }
        if hasSuffix {
            guard separators == 1 else { return nil }
            return Double(token.replacingOccurrences(of: ",", with: "."))
        }
        let groups = token.split(whereSeparator: { $0 == "," || $0 == "." })
        guard groups.count > 1, groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        return Double(groups.joined())
    }

    // MARK: Durations

    /// "4:19:10" → 15550, "4:40" → 280, "0:59" → 59. Anything that is not `[h:]m:s` ("LIVE") and nil give nil.
    public static func parseDuration(_ text: String?) -> Int? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let value = Int(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// ISO 8601 durations as used by the Data API: "PT1H2M3S" → 3723, "PT4M40S" → 280, "PT59S" → 59, "P0D" → 0,
    /// "P1DT1S" → 86401. Years and months are not fixed lengths and give nil, as does anything malformed.
    public static func parseISO8601Duration(_ s: String?) -> Int? {
        guard let s else { return nil }
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.first == "P" else { return nil }

        var seconds = 0.0
        var inTimePart = false
        var number = ""
        var sawComponent = false
        for character in text.dropFirst() {
            if character == "T" {
                guard !inTimePart, number.isEmpty else { return nil }
                inTimePart = true
            } else if character.isASCIIDigit || character == "." || character == "," {
                number.append(character == "," ? "." : character)
            } else {
                guard let value = Double(number) else { return nil }
                number = ""
                switch (character, inTimePart) {
                case ("W", false): seconds += value * 7 * 86_400
                case ("D", false): seconds += value * 86_400
                case ("H", true): seconds += value * 3_600
                case ("M", true): seconds += value * 60
                case ("S", true): seconds += value
                default: return nil
                }
                sawComponent = true
            }
        }
        guard number.isEmpty, sawComponent else { return nil }
        return Int(exactly: seconds.rounded())
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        "0"..."9" ~= self
    }
}
