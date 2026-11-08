import Foundation

/// What a `get_panel` reply offers for one Home card. The feedback tokens are request material: the description shows
/// only whether each is present.
public struct TVPanelFindings: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let notInterested: String?
    public let dontRecommend: String?
    public let channelID: String?
    public let channelName: String?
    public let handle: String?
    /// More than one candidate of a kind was found: both tokens are nil and nothing may be sent.
    public let ambiguous: Bool

    public init(
        notInterested: String?, dontRecommend: String?, channelID: String?, channelName: String?, handle: String?,
        ambiguous: Bool
    ) {
        self.notInterested = notInterested
        self.dontRecommend = dontRecommend
        self.channelID = channelID
        self.channelName = channelName
        self.handle = handle
        self.ambiguous = ambiguous
    }

    public var description: String {
        "TVPanelFindings(notInterested: \(notInterested == nil ? "no" : "yes"), dontRecommend: \(dontRecommend == nil ? "no" : "yes"), "
            + "channel: \(channelID == nil ? "no" : "yes"), ambiguous: \(ambiguous))"
    }

    public var debugDescription: String { description }
}

/// Finds "Not interested" and "Don't recommend channel" in a `get_panel` reply by structure, never by text (the
/// text follows the request language). Port of `scripts/tv-probe/tvprobe/panel.py`.
///
/// - A `feedbackEndpoint` inside an `openPopupAction` is "Don't recommend channel" (it asks to confirm first).
/// - A `feedbackEndpoint` outside a popup that carries a dismissal follow-up is "Not interested".
/// - Any other `feedbackEndpoint` is ignored.
public enum TVPanelParser {
    public static func parse(_ reply: JSON) -> TVPanelFindings {
        var walk = Walk()
        visit(reply, inPopup: false, &walk)
        let notInterested = unique(walk.notInterested)
        let dontRecommend = unique(walk.dontRecommend)
        var handle: String?
        var name: String?
        for text in walk.strings {
            if let found = handleAndName(in: text) {
                handle = found.handle
                name = found.name
                break
            }
        }
        let ids = unique(walk.channelIDs)
        // Several channels: unknown, so "Don't recommend" fails closed.
        let channel = ids.count == 1 ? ids[0] : nil
        if notInterested.count > 1 || dontRecommend.count > 1 {
            return TVPanelFindings(notInterested: nil, dontRecommend: nil, channelID: channel, channelName: name, handle: handle, ambiguous: true)
        }
        return TVPanelFindings(
            notInterested: notInterested.first, dontRecommend: dontRecommend.first,
            channelID: channel, channelName: name, handle: handle, ambiguous: false
        )
    }

    private struct Walk {
        var notInterested: [String] = []
        var dontRecommend: [String] = []
        var strings: [String] = []
        var channelIDs: [String] = []
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func visit(_ node: JSON, inPopup: Bool, _ walk: inout Walk) {
        switch node {
        case .object(let object):
            for key in object.keys.sorted() {
                guard let value = object[key] else { continue }
                if key == "feedbackEndpoint", case .object = value {
                    if let token = value["feedbackToken"]?.string, !token.isEmpty {
                        if inPopup {
                            walk.dontRecommend.append(token)
                        } else if hasDismissal(value) {
                            walk.notInterested.append(token)
                        }
                    }
                    continue
                }
                if key == "browseEndpoint", case .object = value,
                   let id = value["browseId"]?.string, isChannelID(id) {
                    walk.channelIDs.append(id)
                }
                visit(value, inPopup: inPopup || key == "openPopupAction", &walk)
            }
        case .array(let list):
            for item in list { visit(item, inPopup: inPopup, &walk) }
        case .string(let text):
            walk.strings.append(text)
        default:
            break
        }
    }

    /// A dismissal follow-up: any key inside the node that names removing or replacing the card.
    private static func hasDismissal(_ node: JSON) -> Bool {
        switch node {
        case .object(let object):
            for (key, value) in object {
                let low = key.lowercased()
                if low.contains("dismiss") || low.contains("replaceenclosing") || low.contains("removefeedback")
                    || low.contains("removecomponent") || low.contains("hideenclosing") || low.contains("uiactions") {
                    return true
                }
                if hasDismissal(value) { return true }
            }
            return false
        case .array(let list):
            return list.contains(where: hasDismissal)
        default:
            return false
        }
    }

    private static func isChannelID(_ text: String) -> Bool {
        guard text.hasPrefix("UC"), text.utf8.count == 24 else { return false }
        return text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 }
    }

    /// "Channel • @handle": the handle after the bullet, the channel name before it.
    private static func handleAndName(in text: String) -> (handle: String, name: String?)? {
        guard let bullet = text.firstIndex(of: "\u{2022}") else { return nil }
        let after = text[text.index(after: bullet)...].drop(while: { $0.isWhitespace })
        guard after.first == "@" else { return nil }
        let handle = String(after.prefix(while: { $0 == "@" || $0 == "." || $0 == "-" || $0 == "_" || $0.isLetter || $0.isNumber }))
        guard handle.count > 1 else { return nil }
        let name = text[..<bullet].trimmingCharacters(in: .whitespacesAndNewlines)
        return (handle, name.isEmpty ? nil : name)
    }
}
