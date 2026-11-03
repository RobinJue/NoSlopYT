import Foundation

/// Parses initial and continuation `search` responses.
///
/// Ads and AI summaries are dropped, Shorts are kept and flagged (`isShort`), and a response with nothing parseable
/// gives an empty page.
public enum SearchParser {
    public static func parse(_ json: JSON) -> Page<SearchItem> {
        // Initial response: the section list of the primary column. Continuation: the items YouTube appends.
        // If YouTube renames the wrappers, everything under `contents` is searched instead.
        let primary = json["contents"]?["twoColumnSearchResultsRenderer"]?["primaryContents"]
        guard let scope = primary?["sectionListRenderer"]?["contents"]
            ?? ItemParser.continuationItems(in: json)
            ?? json["contents"]
        else { return Page() }

        let found = ItemParser.harvest(scope)
        return Page(items: found.items, continuation: found.continuation)
    }
}
