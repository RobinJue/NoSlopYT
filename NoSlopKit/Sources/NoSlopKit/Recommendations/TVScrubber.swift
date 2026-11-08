import Foundation

/// Scrubbed copies of YouTube replies for the diagnostics sample: nothing secret, nothing that identifies the account,
/// plus a leak check. A port of the probe's `scrub.py`.
public enum TVScrubber {
    static let placeholder = "REDACTED"
    static let safeIP = "203.0.113.7"

    private static let secretKey = regex("token|params|visitordata|serializedshareentity|datasyncid|delegatedsessionid|gaiaid|accountname", caseInsensitive: true)
    private static let trackingURL = regex(#"https?://[^\s"'<>]*?(?:googlevideo\.com|s\.youtube\.com|/api/stats/)[^\s"'<>]*"#)
    private static let ipv4 = regex(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?!\.?\d)"#)
    private static let leakPatterns = [
        regex(#"ya29\.[A-Za-z0-9._-]+"#),
        regex(#"(?<![\w/:.])1//[A-Za-z0-9._-]+"#),
        regex(#"Bearer\s+[A-Za-z0-9._~+/=-]+"#),
    ]
    private static let dropped: Set<String> = ["frameworkUpdates"]
    private static let titleKeys: Set<String> = ["title", "headline"]
    private static let channelKeys: Set<String> = ["shortBylineText", "longBylineText", "ownerText", "channelName"]
    private static let textKeys: Set<String> = ["simpleText", "text", "content"]

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // The patterns are constants of this file; a failure here is a programming error caught by the tests.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func contains(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A new value without tokens, params, visitorData, tracking URLs, IP addresses or the account's ids.
    /// - Parameter hideTitles: replaces video titles and channel names with numbered labels.
    public static func scrub(_ reply: JSON, hideTitles: Bool = false) -> JSON {
        var worker = Worker(hideTitles: hideTitles)
        var result = worker.walk(reply, key: "")
        if case .object(var object) = result, reply["responseContext"] != nil {
            object["_loggedIn"] = loggedIn(reply).map { JSON.bool($0) } ?? .null
            result = .object(object)
        }
        return result
    }

    /// Token prefixes, bearer headers and IPv4 addresses other than the documentation address.
    public static func leaks(_ text: String) -> [String] {
        var found: [String] = []
        for pattern in leakPatterns { found.append(contentsOf: matches(pattern, in: text)) }
        found.append(contentsOf: matches(ipv4, in: text).filter { $0 != safeIP })
        return found
    }

    private static func loggedIn(_ reply: JSON) -> Bool? {
        for service in reply["responseContext"]?["serviceTrackingParams"]?.array ?? [] where service["service"]?.string == "GFEEDBACK" {
            for param in service["params"]?.array ?? [] where param["key"]?.string == "logged_in" {
                switch param["value"]?.string {
                case "1": return true
                case "0": return false
                default: break
                }
            }
        }
        return nil
    }

    private struct Worker {
        let hideTitles: Bool
        var continuations: [String: String] = [:]
        var titles: [String: String] = [:]
        var channels: [String: String] = [:]

        init(hideTitles: Bool) { self.hideTitles = hideTitles }

        private mutating func label(_ kind: String, _ original: String) -> String {
            if kind == "Title" {
                if let known = titles[original] { return known }
                let made = "Title \(titles.count + 1)"
                titles[original] = made
                return made
            }
            if let known = channels[original] { return known }
            let made = "Channel \(channels.count + 1)"
            channels[original] = made
            return made
        }

        private func string(_ text: String) -> String {
            var out = text
            let tracking = TVScrubber.trackingURL
            out = tracking.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "https://example.invalid/")
            // Token-shaped text in a plain string goes too (the probe only reported it).
            for pattern in TVScrubber.leakPatterns {
                out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: TVScrubber.placeholder)
            }
            let ip = TVScrubber.ipv4
            return ip.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: TVScrubber.safeIP)
        }

        /// Every string below a secret key is replaced, whatever the shape.
        private func blank(_ node: JSON) -> JSON {
            switch node {
            case .object(let object): return .object(object.mapValues(blank))
            case .array(let array): return .array(array.map(blank))
            case .string: return .string(TVScrubber.placeholder)
            default: return node
            }
        }

        /// Replaces the text under a title or channel node (simpleText, runs, content).
        private mutating func relabel(_ node: JSON, _ kind: String) -> JSON {
            switch node {
            case .string(let text): return .string(label(kind, text))
            case .array(let array): return .array(array.map { relabel($0, kind) })
            case .object(let object):
                var out: [String: JSON] = [:]
                for (key, value) in object {
                    out[key] = (TVScrubber.textKeys.contains(key) || key == "runs") ? relabel(value, kind) : walk(value, key: "")
                }
                return .object(out)
            default: return node
            }
        }

        /// The first metadata line of a tile is its channel name.
        private mutating func channelLine(_ line: JSON) -> JSON {
            guard case .object(let object) = line else { return walk(line, key: "") }
            var out: [String: JSON] = [:]
            for (key, value) in object {
                switch value {
                case _ where key == "text": out[key] = relabel(value, "Channel")
                case .object: out[key] = channelLine(value)
                case .array(let array): out[key] = .array(array.map { channelLine($0) })
                case .string(let text): out[key] = .string(string(text))
                default: out[key] = value
                }
            }
            return .object(out)
        }

        mutating func walk(_ node: JSON, key: String) -> JSON {
            switch node {
            case .object(let object):
                var out: [String: JSON] = [:]
                for name in object.keys.sorted() {
                    guard let value = object[name] else { continue }
                    if TVScrubber.dropped.contains(name) { continue }
                    if name == "serviceTrackingParams" && key == "responseContext" { continue }
                    if TVScrubber.contains(TVScrubber.secretKey, name) {
                        out[name] = blank(value)
                    } else if name == "continuation", case .string(let token) = value {
                        if continuations[token] == nil { continuations[token] = "CONTINUATION_\(continuations.count + 1)" }
                        out[name] = .string(continuations[token] ?? "CONTINUATION")
                    } else if hideTitles && TVScrubber.titleKeys.contains(name) {
                        out[name] = relabel(value, "Title")
                    } else if hideTitles && TVScrubber.channelKeys.contains(name) {
                        out[name] = relabel(value, "Channel")
                    } else if hideTitles && name == "lines", case .array(let lines) = value, let first = lines.first {
                        var rest: [JSON] = [channelLine(first)]
                        for line in lines.dropFirst() { rest.append(walk(line, key: name)) }
                        out[name] = .array(rest)
                    } else {
                        out[name] = walk(value, key: name)
                    }
                }
                return .object(out)
            case .array(let array):
                return .array(array.map { walk($0, key: key) })
            case .string(let text):
                return .string(string(text))
            default:
                return node
            }
        }
    }
}
