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

    /// Parses YouTube's count strings, and returns a number only when it is sure of it. Text it cannot read exactly
    /// gives nil, and callers keep YouTube's own wording in that case.
    ///
    /// Read:
    /// - Counts written out, their digits grouped by commas, dots, spaces, no-break spaces or narrow no-break
    ///   spaces: "2,763,792 views", "2.763.792 Aufrufe" and "2 763 792 vues" all give 2763792. A Latin-script word
    ///   after such a number is the noun that is counted.
    /// - English abbreviations glued to the number: "810K views" → 810000, "1.25M subscribers" → 1250000,
    ///   "1.5K videos" → 1500, "3B" → 3000000000.
    /// - German abbreviations: "110 Tsd." → 110000, "1,25 Mio. Abonnenten" → 1250000, "3,2 Mrd." → 3200000000.
    /// - A short number and an English or German noun ("1 view", "8 lessons", "12 Aufrufe", "5 months ago"), and
    ///   "No views" or "No subscribers" → 0.
    ///
    /// Anything else gives nil. In particular a number followed by a unit this function does not know does, because
    /// reading only the number would be off by a factor of a thousand or more: "12万 回視聴", "12 тыс. просмотров",
    /// "12 tn visningar", "578 thousand subscribers". Even the letters K, M and B are only read the English way, glued
    /// to the number and followed by English words: in Indonesian "M" is a billion and in Turkish "B" is a thousand.
    /// Text without a number ("watching") and nil give nil too.
    public static func parseCount(_ text: String?) -> Int? {
        guard let text else { return nil }
        return CountText.parse(text)
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

private extension Unicode.Scalar {
    var isASCIIDigit: Bool {
        "0"..."9" ~= self
    }
}

// MARK: - Reading counts

/// One reading of a count string for `InnerTubeText.parseCount`: the number first, then what follows it.
private enum CountText {
    /// What may follow a short number: the things YouTube counts, in English and German, and the units of an age
    /// ("5 months ago"). Lowercase.
    static let nouns: Set<String> = [
        "view", "views", "subscriber", "subscribers", "video", "videos", "lesson", "lessons", "episode", "episodes",
        "watching", "waiting", "like", "likes", "comment", "comments", "reply", "replies", "other", "others", "people",
        "aufruf", "aufrufe", "abonnent", "abonnenten", "kommentar", "kommentare", "antwort", "antworten", "anderen",
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks", "month", "months",
        "year", "years",
    ]

    /// Spelled-out magnitudes. A number written out in full is never followed by one.
    static let spelledOutMagnitudes: Set<String> = [
        "thousand", "million", "billion", "trillion", "tausend", "millionen", "milliarde", "milliarden",
    ]

    /// The German abbreviations ("Tsd.", "Mio.", "Mrd."), lowercase and without the dot.
    static let germanMagnitudes: [String: Double] = ["tsd": 1_000, "mio": 1_000_000, "mrd": 1_000_000_000]

    /// Punctuation that may follow a count without being part of it ("2.7M • 3 days ago", "10K+ views").
    static let punctuation: Set<Unicode.Scalar> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "+", "\u{2022}", "\u{00B7}", "|"]

    /// What directly in front of the first digit makes it a sign or a fraction ("-5", ".5K") rather than a count.
    static let signs: Set<Unicode.Scalar> = ["-", "\u{2212}", "\u{2013}", ".", ","]

    // MARK: Number

    /// The number at the start of a count, and how it was written.
    struct Number {
        enum Form {
            /// "12", "1234": digits only. Up to three of them might be an abbreviated count ("12 Tsd.").
            case plain
            /// "2,763,792", "2.763.792", "2 763 792": written out in full. `ambiguous` marks a single group
            /// ("1,234"), which next to a unit would rather be a decimal fraction.
            case grouped(ambiguous: Bool)
            /// "1,25" or "1.25": a fraction, which only an abbreviated count has.
            case decimal(fraction: String)
        }

        /// The integer part, with the groups joined.
        var digits: String
        var form: Form
        /// The index of the first scalar after the number.
        var end: Int

        /// Whether the number is written out in full, so that no abbreviation can follow it.
        var isExact: Bool {
            switch form {
            case .plain: return digits.count > 3
            case .grouped: return true
            case .decimal: return false
            }
        }
    }

    static func parse(_ text: String) -> Int? {
        // Direction marks and other invisible format characters carry no meaning here.
        var scalars = Array(text.unicodeScalars.filter { $0.properties.generalCategory != .format })
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        scalars.removeFirst(scalars.prefix(while: isSpace).count)
        guard !scalars.isEmpty else { return nil }

        guard let start = scalars.firstIndex(where: \.isASCIIDigit) else { return explicitZero(scalars) }
        if start > 0, signs.contains(scalars[start - 1]) { return nil }
        guard let number = scanNumber(in: scalars, from: start) else { return nil }
        return value(of: number, followedBy: scalars[number.end...])
    }

    /// "No views", "No subscribers": an explicit zero. Any other text without a digit has no count.
    static func explicitZero(_ scalars: [Unicode.Scalar]) -> Int? {
        let words = scalars.split(whereSeparator: isSpace)
        guard words.count >= 2, String(String.UnicodeScalarView(words[0])).lowercased() == "no" else { return nil }
        return nouns.contains(word(at: words[1])) ? 0 : nil
    }

    static func scanNumber(in scalars: [Unicode.Scalar], from start: Int) -> Number? {
        let head = digitRun(in: scalars, from: start)
        // Up to three digits, not starting with a zero: the first group of a grouped number.
        let startsGroups = head.digits.count <= 3 && head.digits.first != "0"

        // Digits joined by "," or ".": thousands groups ("2,763,792") or a decimal fraction ("1,25").
        if isDigitSeparator(at: head.end, in: scalars) {
            let separator = scalars[head.end]
            var runs = [head.digits]
            var end = head.end
            while end + 1 < scalars.count, scalars[end] == separator, scalars[end + 1].isASCIIDigit {
                let run = digitRun(in: scalars, from: end + 1)
                runs.append(run.digits)
                end = run.end
            }
            // "1,234.5" and "1.234,5" mix both ways of writing a number.
            if isDigitSeparator(at: end, in: scalars) { return nil }

            if runs.count == 2 {
                if startsGroups, runs[1].count == 3 {
                    return Number(digits: runs.joined(), form: .grouped(ambiguous: true), end: end)
                }
                return Number(digits: runs[0], form: .decimal(fraction: runs[1]), end: end)
            }
            guard startsGroups, runs.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            return Number(digits: runs.joined(), form: .grouped(ambiguous: false), end: end)
        }

        // Digits joined by spaces ("2 763 792"): every group after the first has exactly three digits.
        if startsGroups {
            var runs = [head.digits]
            var end = head.end
            while end + 3 < scalars.count, isGroupSpace(scalars[end]),
                  scalars[(end + 1)...(end + 3)].allSatisfy(\.isASCIIDigit),
                  end + 4 >= scalars.count || !scalars[end + 4].isASCIIDigit {
                runs.append(String(String.UnicodeScalarView(scalars[(end + 1)...(end + 3)])))
                end += 4
            }
            if runs.count > 1 {
                if isDigitSeparator(at: end, in: scalars) { return nil }
                return Number(digits: runs.joined(), form: .grouped(ambiguous: false), end: end)
            }
        }

        return Number(digits: head.digits, form: .plain, end: head.end)
    }

    // MARK: What follows the number

    static func value(of number: Number, followedBy tail: ArraySlice<Unicode.Scalar>) -> Int? {
        let rest = tail.drop(while: isSpace)
        let isGlued = rest.startIndex == tail.startIndex

        if let unit = germanMagnitude(in: rest) {
            return scaled(number, by: unit.factor)
        }
        if isGlued, let unit = englishMagnitude(in: rest) {
            // Only English words may follow an English abbreviation.
            guard isAcceptable(rest[unit.end...], mayBeAnyWord: false) else { return nil }
            return scaled(number, by: unit.factor)
        }

        // No unit: the number stands for itself, so a fraction ("1,25") is no count.
        if case .decimal = number.form { return nil }
        guard isAcceptable(rest, mayBeAnyWord: number.isExact) else { return nil }
        return Int(number.digits)
    }

    /// "Tsd.", "Mio." and "Mrd." as whole words, in any case, the dot optional.
    static func germanMagnitude(in rest: ArraySlice<Unicode.Scalar>) -> (factor: Double, end: Int)? {
        let letters = rest.prefix(while: { $0.isASCII && $0.properties.isAlphabetic })
        guard letters.count == 3,
              let factor = germanMagnitudes[String(String.UnicodeScalarView(letters)).lowercased()] else { return nil }
        var end = letters.endIndex
        if end < rest.endIndex, rest[end].properties.isAlphabetic { return nil }  // "Mio" is the start of another word
        if end < rest.endIndex, rest[end] == "." { end += 1 }
        return (factor, end)
    }

    /// "K", "M" and "B" as whole words, in either case.
    static func englishMagnitude(in rest: ArraySlice<Unicode.Scalar>) -> (factor: Double, end: Int)? {
        guard let first = rest.first else { return nil }
        let factor: Double
        switch first.value {
        case 0x4B, 0x6B: factor = 1_000
        case 0x4D, 0x6D: factor = 1_000_000
        case 0x42, 0x62: factor = 1_000_000_000
        default: return nil
        }
        let end = rest.startIndex + 1
        if end < rest.endIndex, rest[end].properties.isAlphabetic { return nil }  // "5months" is not "5M"
        return (factor, end)
    }

    /// The value of an abbreviated count: 1,25 and "Mio." → 1250000. Only a number that could have been abbreviated
    /// (up to three digits in front of the fraction) takes a unit.
    static func scaled(_ number: Number, by factor: Double) -> Int? {
        let mantissa: Double?
        switch number.form {
        case .plain where number.digits.count <= 3:
            mantissa = Double(number.digits)
        case .decimal(let fraction) where number.digits.count <= 3:
            mantissa = Double("\(number.digits).\(fraction)")
        default:
            // Written out in full ("1,234 Mio."), or a single group that could just as well be a fraction ("1,234"
            // next to a unit): two readings, so no reading.
            mantissa = nil
        }
        guard let mantissa else { return nil }
        return Int(exactly: (mantissa * factor).rounded())
    }

    /// Whether `rest` may follow a count: nothing, punctuation, or a Latin-script word that is a known noun (or any
    /// word of four letters or more when `mayBeAnyWord`, as after a number that is written out in full).
    static func isAcceptable(_ rest: ArraySlice<Unicode.Scalar>, mayBeAnyWord: Bool) -> Bool {
        let rest = rest.drop(while: isSpace)
        guard let first = rest.first else { return true }
        if first.properties.isAlphabetic {
            guard isLatinLetter(first) else { return false }
            let word = word(at: rest)
            if nouns.contains(word) { return true }
            return mayBeAnyWord && word.count >= 4 && !spelledOutMagnitudes.contains(word)
        }
        return punctuation.contains(first)
    }

    // MARK: Characters

    /// The digits from `start` on.
    static func digitRun(in scalars: [Unicode.Scalar], from start: Int) -> (digits: String, end: Int) {
        var end = start
        while end < scalars.count, scalars[end].isASCIIDigit { end += 1 }
        return (String(String.UnicodeScalarView(scalars[start..<end])), end)
    }

    /// Whether a "," or "." followed by a digit starts at `index`.
    static func isDigitSeparator(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        index + 1 < scalars.count && (scalars[index] == "," || scalars[index] == ".") && scalars[index + 1].isASCIIDigit
    }

    /// The Latin letters at the start of `scalars`, lowercased.
    static func word<Scalars: Collection>(at scalars: Scalars) -> String where Scalars.Element == Unicode.Scalar {
        let letters = scalars.prefix(while: { isLatinLetter($0) || (0x300...0x36F).contains($0.value) })
        return String(String.UnicodeScalarView(letters)).lowercased()
    }

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    /// Spaces that separate digit groups: a plain space, a no-break space, a narrow no-break space, a thin space.
    static func isGroupSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .spaceSeparator
    }

    /// Letters of the Latin script (ASCII, Latin-1, Latin Extended-A and -B, Latin Extended Additional).
    static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic else { return false }
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xB5, 0xBA, 0x1E00...0x1EFF: return true
        case 0xC0...0x24F: return scalar.value != 0xD7 && scalar.value != 0xF7
        default: return false
        }
    }
}
