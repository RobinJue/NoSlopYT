import Foundation

/// Parses WebVTT text into caption cues.
///
/// Lenient by design: lines are scanned for timing lines (`start --> end [settings]`), and the text lines up to the
/// next empty line belong to that cue. The `WEBVTT` header, `NOTE`/`STYLE`/`REGION` blocks and cue identifiers
/// precede or sit between cues and are therefore skipped without being recognised. Per cue line, `<…>` tags are
/// stripped and the common entities decoded; lines that end up empty are dropped, and so are cues without text.
/// Cues come back sorted by start time (stable), so the caller can search them.
///
/// Only a truly empty line ends a cue: YouTube's auto-generated tracks put a lone space on the first line of many
/// cues, and that line is payload.
public enum WebVTTParser {
    public static func parse(_ text: String) -> [CaptionCue] {
        let lines = normalizedLines(of: text)

        var cues: [CaptionCue] = []
        var timing: (start: Double, end: Double)?
        var payload: [String] = []

        func finishCue() {
            defer {
                timing = nil
                payload = []
            }
            guard let current = timing else { return }
            let body = payload.map(cleaned).filter { !$0.isEmpty }.joined(separator: "\n")
            if !body.isEmpty {
                cues.append(CaptionCue(start: current.start, end: current.end, text: body))
            }
        }

        for line in lines {
            if line.isEmpty {
                finishCue()
            } else if line.contains("-->") {
                // "-->" never occurs in cue text, so this starts a cue. When its timing cannot be read the cue is
                // lost, and so are its text lines (nothing is active), instead of sticking to the previous cue.
                finishCue()
                timing = parseTiming(line)
            } else if timing != nil {
                payload.append(line)
            }
            // Anything else (header, NOTE/STYLE/REGION blocks, cue identifiers) comes before a timing line.
        }
        finishCue()

        // Normally already in order; a stable sort keeps equal starts in their file order.
        return cues.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    // MARK: Lines

    /// Lines with "\r\n" and "\r" turned into "\n" (Swift reads "\r\n" as one character, which would defeat
    /// splitting on "\n") and a leading byte order mark removed.
    private static func normalizedLines(of text: String) -> [String] {
        var normalized = text
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        normalized = normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: Timing

    private static func parseTiming(_ line: String) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let startText = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        // After the end time come optional cue settings ("align:start position:0%"), which are ignored.
        let endText = line[arrow.upperBound...]
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)
        guard let start = timestamp(startText), let endText, let end = timestamp(endText), end >= start else { return nil }
        return (start, end)
    }

    /// "HH:MM:SS.mmm" or "MM:SS.mmm" (also with a comma, and with fewer or more fraction digits) as seconds.
    /// Computed in whole milliseconds and divided once, so 18.64 is exactly the double nearest 18.64.
    private static func timestamp(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let secondsAndFraction = parts[parts.count - 1].split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "," })
        guard secondsAndFraction.count <= 2 else { return nil }

        var numbers: [Int] = []
        for part in parts.dropLast() + [secondsAndFraction[0]] {
            guard let value = wholeNumber(part) else { return nil }
            numbers.append(value)
        }

        var milliseconds = 0
        if secondsAndFraction.count == 2 {
            let fraction = secondsAndFraction[1]
            guard fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            milliseconds = Int(fraction.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        }

        let hours = numbers.count == 3 ? numbers[0] : 0
        let minutes = numbers[numbers.count - 2]
        let seconds = numbers[numbers.count - 1]
        return Double(((hours * 60 + minutes) * 60 + seconds) * 1_000 + milliseconds) / 1_000
    }

    /// Digits only, at most nine of them, so the arithmetic above cannot overflow.
    private static func wholeNumber(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    // MARK: Text

    private static func cleaned(_ line: String) -> String {
        decodingEntities(in: strippingTags(from: line)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes `<…>` (voice, class, ruby and timestamp tags). A "<" with no ">" after it is ordinary text.
    private static func strippingTags(from line: String) -> String {
        guard line.contains("<") else { return line }
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "<" {
                guard let close = line[index...].firstIndex(of: ">") else {
                    // No ">" follows this "<", so none follows a later "<" either: the rest of the line is text.
                    // (Searching again from every "<" would cost n² steps for a line of n of them.)
                    result += line[index...]
                    break
                }
                index = line.index(after: close)
            } else {
                result.append(line[index])
                index = line.index(after: index)
            }
        }
        return result
    }

    /// Decodes `&amp; &lt; &gt; &quot; &apos; &nbsp; &lrm; &rlm;` and numeric references (`&#39;`, `&#x266A;`) in
    /// one pass, so "&amp;lt;" becomes "&lt;" and not "<". Unknown or malformed references are left as they are.
    private static func decodingEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&",
               let semicolon = text[index...].prefix(12).firstIndex(of: ";"),
               let decoded = entityValue(text[text.index(after: index)..<semicolon]) {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func entityValue(_ name: Substring) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "lrm": return "\u{200E}"
        case "rlm": return "\u{200F}"
        default: break
        }
        guard name.hasPrefix("#"), name.count > 1 else { return nil }
        let digits = name.dropFirst()
        let codePoint: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            codePoint = UInt32(digits.dropFirst(), radix: 16)
        } else {
            codePoint = UInt32(digits, radix: 10)
        }
        guard let value = codePoint, value > 0, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}
