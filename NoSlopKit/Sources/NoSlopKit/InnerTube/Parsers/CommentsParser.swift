import Foundation

/// Parses comment and reply pages from a `next` continuation response.
///
/// A page has two parts:
/// - **List items** in `onResponseReceivedEndpoints[]` → `reloadContinuationItemsCommand` /
///   `appendContinuationItemsAction` → `continuationItems[]`: a `commentThreadRenderer` per top-level comment, a bare
///   `commentViewModel` per reply, a trailing `continuationItemRenderer` (the next page) and, on the first page,
///   a `commentsHeaderRenderer` (count and sort menu). Items only name entity keys.
/// - **Entities** in `frameworkUpdates.entityBatchUpdate.mutations[]`, keyed by `entityKey`: the
///   `commentEntityPayload` with the text, author and counts, and the `engagementToolbarStateEntityPayload` with the
///   creator heart.
///
/// Like every parser here it never throws: a comment whose entity is missing is skipped, and a response with nothing
/// recognisable is an empty page.
public enum CommentsParser {
    public static func parse(_ json: JSON) -> CommentsPage {
        let entities = entityPayloads(in: json)
        var page = CommentsPage()
        var seenIDs = Set<String>()

        func add(_ comment: Comment?) {
            guard let comment, seenIDs.insert(comment.id).inserted else { return }
            page.comments.append(comment)
        }

        for action in continuationActions(in: json) {
            for item in action["continuationItems"]?.array ?? [] {
                if let thread = item["commentThreadRenderer"] {
                    add(comment(
                        viewModel: viewModel(in: thread["commentViewModel"]),
                        repliesContinuation: repliesContinuation(of: thread),
                        entities: entities
                    ))
                } else if let reply = item["commentViewModel"] {
                    add(comment(viewModel: viewModel(in: reply), repliesContinuation: nil, entities: entities))
                } else if let more = item["continuationItemRenderer"] {
                    if let token = continuationToken(of: more) { page.continuation = token }
                } else if let header = item["commentsHeaderRenderer"] {
                    apply(header: header, to: &page)
                }
            }
        }
        return page
    }

    /// The token inside a `continuationItemRenderer`: `continuationEndpoint…token` (a page of comments, or the replies
    /// of a thread) or `button.buttonRenderer.command…token` ("Show more replies"). Also used by
    /// `WatchMetadataParser` for the comments section of the watch page.
    static func continuationToken(of renderer: JSON) -> String? {
        if let token = renderer["continuationEndpoint"]?["continuationCommand"]?["token"]?.string, !token.isEmpty {
            return token
        }
        let buttonCommand = renderer["button"]?["buttonRenderer"]?["command"]
        if let token = buttonCommand?["continuationCommand"]?["token"]?.string, !token.isEmpty {
            return token
        }
        // The same command inside some other wrapper (for example a command executor).
        if let token = renderer.first("continuationCommand")?["token"]?.string, !token.isEmpty {
            return token
        }
        return nil
    }

    // MARK: Response structure

    /// The `reloadContinuationItemsCommand` / `appendContinuationItemsAction` objects of the response, in order.
    private static func continuationActions(in json: JSON) -> [JSON] {
        let endpoints = (json["onResponseReceivedEndpoints"]?.array ?? []) + (json["onResponseReceivedActions"]?.array ?? [])
        return endpoints.compactMap { $0["reloadContinuationItemsCommand"] ?? $0["appendContinuationItemsAction"] }
    }

    /// `entityKey` → payload (`{"commentEntityPayload": {…}}` and friends) for every mutation that has both.
    private static func entityPayloads(in json: JSON) -> [String: JSON] {
        var payloads: [String: JSON] = [:]
        for mutation in json["frameworkUpdates"]?["entityBatchUpdate"]?["mutations"]?.array ?? [] {
            guard let payload = mutation["payload"], let typed = payload.object else { continue }
            // The payload repeats the key as `<payload>.key`; use that when the mutation does not carry one.
            guard let key = mutation["entityKey"]?.string ?? typed.values.lazy.compactMap({ $0["key"]?.string }).first,
                  !key.isEmpty else { continue }
            payloads[key] = payload
        }
        return payloads
    }

    /// Threads wrap the view model twice (`commentViewModel.commentViewModel`), replies once.
    private static func viewModel(in node: JSON?) -> JSON? {
        node?["commentViewModel"] ?? node
    }

    private static func repliesContinuation(of thread: JSON) -> String? {
        let items = thread["replies"]?["commentRepliesRenderer"]?["contents"]?.array ?? []
        return items.lazy.compactMap { $0["continuationItemRenderer"] }.compactMap(continuationToken(of:)).first
    }

    // MARK: Header

    private static func apply(header: JSON, to page: inout CommentsPage) {
        // "5,222 Comments" on the first page; some responses only have the short "5.2K" or a bare "Comments".
        let counts = [InnerTubeText.text(header["countText"]), InnerTubeText.text(header["commentsCount"])]
        page.totalCountText = counts.lazy.compactMap { $0 }.first { text in text.contains(where: \.isNumber) }

        let items = header["sortMenu"]?["sortFilterSubMenuRenderer"]?["subMenuItems"]?.array ?? []
        page.sortOptions = items.compactMap { item in
            guard let title = InnerTubeText.text(item["title"]),
                  let token = item["serviceEndpoint"]?["continuationCommand"]?["token"]?.string,
                  !token.isEmpty else { return nil }
            return CommentSortOption(title: title, continuation: token, isSelected: item["selected"]?.bool ?? false)
        }
    }

    // MARK: Comments

    private static func comment(viewModel: JSON?, repliesContinuation: String?, entities: [String: JSON]) -> Comment? {
        guard let viewModel,
              let commentKey = viewModel["commentKey"]?.string,
              let entity = entities[commentKey]?["commentEntityPayload"] else { return nil }

        let properties = entity["properties"]
        guard let id = properties?["commentId"]?.string ?? viewModel["commentId"]?.string, !id.isEmpty else { return nil }

        let author = entity["author"]
        let toolbar = entity["toolbar"]
        let toolbarStateKey = viewModel["toolbarStateKey"]?.string ?? properties?["toolbarStateKey"]?.string

        return Comment(
            id: id,
            authorName: author?["displayName"]?.string ?? properties?["authorButtonA11y"]?.string ?? "",
            authorAvatarURL: url(author?["avatarThumbnailUrl"]?.string),
            authorChannelID: nonEmpty(author?["channelId"]?.string),
            text: trimmed(InnerTubeText.text(properties?["content"])) ?? "",
            publishedText: trimmed(properties?["publishedTime"]?.string) ?? "",
            // A comment without likes has a blank (" ") count.
            likeCountText: trimmed(toolbar?["likeCountNotliked"]?.string),
            replyCount: count(toolbar?["replyCount"]),
            repliesContinuation: repliesContinuation,
            // `pinnedText` ("Pinned by …") sits on the view model.
            isPinned: isPresent(viewModel["pinnedText"]) || isPresent(properties?["pinnedText"]),
            isByUploader: author?["isCreator"]?.bool ?? false,
            isHearted: isHearted(toolbarStateKey: toolbarStateKey, entities: entities)
        )
    }

    private static func isHearted(toolbarStateKey: String?, entities: [String: JSON]) -> Bool {
        guard let toolbarStateKey,
              let state = entities[toolbarStateKey]?["engagementToolbarStateEntityPayload"] else { return false }
        return state["heartState"]?.string == "TOOLBAR_HEART_STATE_HEARTED"
    }

    /// Reply counts come as strings, blank for none ("25", ""), but tolerate numbers and abbreviations ("1.2K").
    private static func count(_ node: JSON?) -> Int {
        guard let node else { return 0 }
        if let whole = node.int { return max(whole, 0) }
        if let text = node.string { return max(InnerTubeText.parseCount(text) ?? 0, 0) }
        return 0
    }

    private static func isPresent(_ node: JSON?) -> Bool {
        guard let node, node != .null else { return false }
        if let text = node.string { return !text.isEmpty }
        return true
    }

    private static func url(_ string: String?) -> URL? {
        guard var text = trimmed(string) else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        return URL(string: text)
    }

    private static func trimmed(_ string: String?) -> String? {
        nonEmpty(string?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }
}
