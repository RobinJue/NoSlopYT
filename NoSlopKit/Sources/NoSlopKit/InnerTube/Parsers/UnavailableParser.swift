import Foundation

/// YouTube's own reason when a page cannot be read because the content is gone: a deleted or private playlist, a
/// terminated channel, a removed or private video. Those are answered with HTTP 200 and a page without a header or a
/// title, and one line that says why.
///
/// - `browse` (channels, playlists): an `alerts[].alertRenderer` of type `ERROR`. Its `text` has `runs` for a
///   playlist and `simpleText` for a channel: "The playlist does not exist.", "This channel does not exist."
/// - `next` (the watch page): the same alert when there is one, else the `backgroundPromoRenderer` that fills the
///   page; its `title` reads "This video isn't available anymore".
///
/// The facade asks only after the real parser found nothing, so a page that can be read is never second-guessed, and
/// an answer without such a line stays what it was: an unexpected format.
enum UnavailableParser {
    static func reason(inBrowse json: JSON) -> String? {
        errorAlert(in: json)
    }

    static func reason(inWatchPage json: JSON) -> String? {
        // The promo is not looked for on browse pages: they have promos of their own ("sign in", empty states).
        errorAlert(in: json) ?? ItemParser.clean(InnerTubeText.text(json.first("backgroundPromoRenderer")?["title"]))
    }

    /// The text of the first alert of type `ERROR` that has any. Warnings and notices are not reasons.
    private static func errorAlert(in json: JSON) -> String? {
        for alert in json["alerts"]?.array ?? [] {
            guard let renderer = alert["alertRenderer"], renderer["type"]?.string?.uppercased() == "ERROR" else { continue }
            if let text = ItemParser.clean(InnerTubeText.text(renderer["text"])) { return text }
        }
        return nil
    }
}
