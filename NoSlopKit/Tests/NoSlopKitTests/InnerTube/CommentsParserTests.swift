import Foundation
import Testing
@testable import NoSlopKit

@Suite struct CommentsParserTests {
    // MARK: - Real responses (plan tests)

    @Test func commentsFirstPage() throws {
        let p = CommentsParser.parse(try Fixture.json("comments_aqz.json"))
        #expect(p.comments.count == 20); #expect(p.totalCountText == "5,222 Comments"); #expect(p.continuation != nil)
        let c = try #require(p.comments.first)
        #expect(c.id == "UgxNivqkidvk9k_eR_B4AaABAg"); #expect(c.authorName == "@randomthef1rst")
        #expect(c.text.hasPrefix("Here after that one TikTok edit")); #expect(c.publishedText == "1 year ago")
        #expect(c.likeCountText == "790"); #expect(c.replyCount == 25); #expect(c.repliesContinuation != nil)
        #expect(p.sortOptions.count == 2); #expect(p.sortOptions.contains { $0.isSelected })
    }

    @Test func commentsContinuation() throws {
        let p = CommentsParser.parse(try Fixture.json("comments_aqz_cont.json"))
        #expect(p.comments.count == 20)
    }

    @Test func repliesPage() throws {
        let p = CommentsParser.parse(try Fixture.json("comments_replies_aqz.json"))
        #expect(!p.comments.isEmpty); #expect(p.comments.allSatisfy { $0.replyCount == 0 })
    }

    @Test func missingEntityMutationSkipsComment() throws {
        let json = try Fixture.json("comments_aqz.json")
        var removed = false
        let mutated = Self.edited(json, "frameworkUpdates.entityBatchUpdate.mutations") { mutations in
            guard case .array(var list) = mutations,
                  let index = list.firstIndex(where: { $0["payload"]?["commentEntityPayload"] != nil }) else { return mutations }
            list.remove(at: index)
            removed = true
            return .array(list)
        }
        #expect(removed)
        let p = CommentsParser.parse(mutated)
        #expect(p.comments.count == 19)
        #expect(p.comments.first?.id != "UgxNivqkidvk9k_eR_B4AaABAg")     // it was the first comment's entity
        #expect(p.continuation != nil); #expect(p.totalCountText == "5,222 Comments")
    }

    // MARK: - Real responses (fields)

    @Test func firstCommentFields() throws {
        let p = CommentsParser.parse(try Fixture.json("comments_aqz.json"))
        let c = try #require(p.comments.first)
        #expect(c.authorChannelID == "UCImHhAGbOH3pdLQ_VU2RZpQ")
        #expect(c.authorAvatarURL?.host == "yt3.ggpht.com")
        #expect(c.text == "Here after that one TikTok edit")
        #expect(!c.isPinned); #expect(!c.isByUploader); #expect(!c.isHearted)
    }

    @Test func sortOptionsCarryTheirTokens() throws {
        let p = CommentsParser.parse(try Fixture.json("comments_aqz.json"))
        #expect(p.sortOptions.map(\.title) == ["Top", "Newest"])
        #expect(p.sortOptions.map(\.isSelected) == [true, false])
        #expect(p.sortOptions.map(\.continuation) == [
            "Eg0SC2Fxei1LRS1icEtRGAYyJSIRIgthcXotS0UtYnBLUTAAeAJCEGNvbW1lbnRzLXNlY3Rpb24%3D",
            "Eg0SC2Fxei1LRS1icEtRGAYyJSIRIgthcXotS0UtYnBLUTABeAJCEGNvbW1lbnRzLXNlY3Rpb24%3D",
        ])
    }

    @Test func continuationPagesCarryNoHeader() throws {
        let first = CommentsParser.parse(try Fixture.json("comments_aqz.json"))
        let next = CommentsParser.parse(try Fixture.json("comments_aqz_cont.json"))
        #expect(next.totalCountText == nil); #expect(next.sortOptions.isEmpty)
        let token = try #require(next.continuation)
        #expect(token != first.continuation)
        #expect(Set(first.comments.map(\.id)).isDisjoint(with: next.comments.map(\.id)))
    }

    @Test(arguments: ["comments_aqz.json", "comments_aqz_cont.json"])
    func replyCountAndRepliesTokenAgree(fixture: String) throws {
        let p = CommentsParser.parse(try Fixture.json(fixture))
        #expect(p.comments.contains { $0.replyCount > 0 }); #expect(p.comments.contains { $0.replyCount == 0 })
        for c in p.comments {
            #expect((c.replyCount > 0) == (c.repliesContinuation != nil), "\(c.id)")
        }
        let ids = p.comments.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(p.comments.allSatisfy { !$0.authorName.isEmpty && !$0.text.isEmpty && !$0.publishedText.isEmpty })
    }

    @Test func zeroLikesHaveNoLikeText() throws {
        // The 10th comment of the first page has a blank (" ") like count.
        let p = CommentsParser.parse(try Fixture.json("comments_aqz.json"))
        let tenth = try #require(p.comments.dropFirst(9).first)
        #expect(tenth.likeCountText == nil)
        #expect(p.comments.filter { $0.likeCountText == nil }.count == 1)
        #expect(Array(p.comments.map(\.likeCountText).prefix(3)) == ["790", "1.9K", "757"])
    }

    @Test func repliesPageShape() throws {
        let p = CommentsParser.parse(try Fixture.json("comments_replies_aqz.json"))
        #expect(p.comments.count == 7)
        #expect(p.comments.allSatisfy { $0.id.hasPrefix("UgxNivqkidvk9k_eR_B4AaABAg.") })     // reply ids extend the parent's
        #expect(p.comments.allSatisfy { $0.repliesContinuation == nil })
        #expect(p.totalCountText == nil); #expect(p.sortOptions.isEmpty)
        // "Show more replies" is a button whose command holds the next token.
        let token = try #require(p.continuation)
        #expect(token.hasPrefix("Eg0SC2Fxei1LRS1icEtRGAYy2AEK"))
        let first = try #require(p.comments.first)
        #expect(first.authorName == "@HJLex"); #expect(first.likeCountText == "22")
        #expect(first.text == "There\u{2019}s hundreds of tiktok edits of this now")
        let edited = try #require(p.comments.dropFirst(5).first)
        #expect(edited.publishedText == "1 year ago (edited)")
        // A reply that starts with a mention has a leading no-break space in the response; the one after the mention stays.
        let last = try #require(p.comments.last)
        #expect(last.text == "@KABKA3KIy_KAPATEJI_05\u{00A0}I was born in 2008 but ok")
    }

    @Test func missingToolbarStateKeepsTheCommentUnhearted() throws {
        let json = try Fixture.json("comments_aqz.json")
        let mutated = Self.edited(json, "frameworkUpdates.entityBatchUpdate.mutations") { mutations in
            guard case .array(let list) = mutations else { return mutations }
            return .array(list.filter { $0["payload"]?["engagementToolbarStateEntityPayload"] == nil })
        }
        let p = CommentsParser.parse(mutated)
        #expect(p.comments.count == 20); #expect(p.comments.allSatisfy { !$0.isHearted })
    }

    // MARK: - Synthetic pages

    @Test func pinnedUploaderAndHeartedFlags() throws {
        let json = Self.page(
            items: [
                Self.thread(id: "A", pinned: true),
                Self.thread(id: "B"),
                Self.thread(id: "C"),
            ],
            mutations: Self.mutations(id: "A", creator: true, hearted: true)
                + Self.mutations(id: "B", hearted: true)
                + Self.mutations(id: "C", creator: true)
        )
        let p = CommentsParser.parse(json)
        #expect(p.comments.map(\.id) == ["A", "B", "C"])
        #expect(p.comments.map(\.isPinned) == [true, false, false])
        #expect(p.comments.map(\.isHearted) == [true, true, false])
        #expect(p.comments.map(\.isByUploader) == [true, false, true])
    }

    @Test func pinnedTextOnTheEntityCountsToo() throws {
        var items = Self.mutations(id: "A")
        items[0] = Self.edited(items[0], "payload.commentEntityPayload.properties") { properties in
            guard case .object(var object) = properties else { return properties }
            object["pinnedText"] = ["runs": [["text": "Pinned by @someone"]]]
            return .object(object)
        }
        let p = CommentsParser.parse(Self.page(items: [Self.thread(id: "A")], mutations: items))
        #expect(p.comments.map(\.isPinned) == [true])
    }

    @Test func replyCountAcceptsEveryShapeYouTubeSends() throws {
        let cases: [(JSON?, Int)] = [("", 0), ("7", 7), (12, 12), ("1.2K", 1_200), ("1,234", 1_234), (nil, 0), (.null, 0), ("no replies", 0)]
        var items: [JSON] = []
        var all: [JSON] = []
        for (index, (value, _)) in cases.enumerated() {
            let id = "c\(index)"
            items.append(Self.thread(id: id))
            var m = Self.mutations(id: id)
            m[0] = Self.edited(m[0], "payload.commentEntityPayload.toolbar") { toolbar in
                guard case .object(var object) = toolbar else { return toolbar }
                object["replyCount"] = value
                return .object(object)
            }
            all += m
        }
        let p = CommentsParser.parse(Self.page(items: items, mutations: all))
        #expect(p.comments.map(\.replyCount) == cases.map(\.1))
    }

    @Test func repliesTokenComesFromTheThread() throws {
        let p = CommentsParser.parse(Self.page(
            items: [Self.thread(id: "A", repliesToken: "tokA"), Self.thread(id: "B")],
            mutations: Self.mutations(id: "A", replies: "3") + Self.mutations(id: "B")
        ))
        #expect(p.comments.map(\.repliesContinuation) == ["tokA", nil])
        #expect(p.comments.map(\.replyCount) == [3, 0])
        #expect(p.continuation == nil)         // the replies token is not the next-page token
    }

    @Test func commentsWithoutAnEntityOrIdAreSkipped() throws {
        let noEntity = Self.thread(id: "ghost")
        let noKey: JSON = .object(["commentThreadRenderer": .object(["commentViewModel": .object(["commentViewModel": .object(["commentId": "x"])])])])
        let emptyId = Self.thread(id: "")
        let p = CommentsParser.parse(Self.page(
            items: [Self.thread(id: "A"), noEntity, noKey, emptyId, Self.thread(id: "B")],
            mutations: Self.mutations(id: "A") + Self.mutations(id: "", key: "key-", toolbarKey: "toolbar-") + Self.mutations(id: "B")
        ))
        #expect(p.comments.map(\.id) == ["A", "B"])
    }

    @Test func duplicateIdsKeepTheFirst() throws {
        let p = CommentsParser.parse(Self.page(
            items: [Self.thread(id: "A", key: "k1"), Self.thread(id: "A", key: "k2")],
            mutations: Self.mutations(id: "A", key: "k1", text: "first") + Self.mutations(id: "A", key: "k2", toolbarKey: "t2", text: "second")
        ))
        #expect(p.comments.map(\.text) == ["first"])
    }

    @Test func textIsTrimmedAndBlankLikesAreNil() throws {
        let p = CommentsParser.parse(Self.page(
            items: [Self.thread(id: "A"), Self.thread(id: "B")],
            mutations: Self.mutations(id: "A", text: "  \n hello \u{1F600}\n ", likes: " ") + Self.mutations(id: "B", text: "x", likes: .null)
        ))
        #expect(p.comments.map(\.text) == ["hello \u{1F600}", "x"])
        #expect(p.comments.map(\.likeCountText) == [nil, nil])
    }

    @Test func protocolRelativeAvatarGetsHTTPS() throws {
        var m = Self.mutations(id: "A")
        m[0] = Self.edited(m[0], "payload.commentEntityPayload.author.avatarThumbnailUrl") { _ in "//yt3.ggpht.com/a=s88" }
        let p = CommentsParser.parse(Self.page(items: [Self.thread(id: "A")], mutations: m))
        #expect(p.comments.first?.authorAvatarURL?.absoluteString == "https://yt3.ggpht.com/a=s88")
    }

    @Test func authorNameFallsBackToTheButtonLabel() throws {
        var m = Self.mutations(id: "A", author: "@display")
        m[0] = Self.edited(m[0], "payload.commentEntityPayload.author.displayName") { _ in nil }
        m[0] = Self.edited(m[0], "payload.commentEntityPayload.properties") { properties in
            guard case .object(var object) = properties else { return properties }
            object["authorButtonA11y"] = "@from-label"
            return .object(object)
        }
        let p = CommentsParser.parse(Self.page(items: [Self.thread(id: "A")], mutations: m))
        #expect(p.comments.map(\.authorName) == ["@from-label"])
    }

    @Test func mutationKeyFallsBackToTheKeyInsideThePayload() throws {
        var m = Self.mutations(id: "A")
        m = m.map { mutation in Self.edited(mutation, "entityKey") { _ in nil } }
        let p = CommentsParser.parse(Self.page(items: [Self.thread(id: "A")], mutations: m))
        #expect(p.comments.map(\.id) == ["A"])
    }

    @Test func viewModelIdIsUsedWhenTheEntityHasNone() throws {
        var m = Self.mutations(id: "A")
        m[0] = Self.edited(m[0], "payload.commentEntityPayload.properties.commentId") { _ in nil }
        let p = CommentsParser.parse(Self.page(items: [Self.thread(id: "A")], mutations: m))
        #expect(p.comments.map(\.id) == ["A"])
    }

    // MARK: - Page token and header (synthetic)

    @Test func trailingContinuationItemIsTheNextPageToken() throws {
        let endpoint = Self.page(items: [Self.thread(id: "A"), Self.continuation(token: "next-endpoint")], mutations: Self.mutations(id: "A"))
        #expect(CommentsParser.parse(endpoint).continuation == "next-endpoint")
        let button = Self.page(items: [Self.thread(id: "A"), Self.continuationButton(token: "next-button")], mutations: Self.mutations(id: "A"))
        #expect(CommentsParser.parse(button).continuation == "next-button")
        let last = Self.page(items: [Self.thread(id: "A")], mutations: Self.mutations(id: "A"))
        #expect(CommentsParser.parse(last).continuation == nil)
    }

    @Test func continuationItemWithoutTokenIsIgnored() throws {
        let broken: JSON = .object(["continuationItemRenderer": .object(["trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN"])])
        let p = CommentsParser.parse(Self.page(items: [Self.thread(id: "A"), broken], mutations: Self.mutations(id: "A")))
        #expect(p.continuation == nil); #expect(p.comments.count == 1)
    }

    @Test func headerGivesCountAndSortOptions() throws {
        let header: JSON = .object(["commentsHeaderRenderer": .object([
            "countText": ["runs": [["text": "1,234"], ["text": " Comments"]]],
            "sortMenu": ["sortFilterSubMenuRenderer": ["subMenuItems": [
                ["title": "Top", "selected": true, "serviceEndpoint": ["continuationCommand": ["token": "top-token"]]],
                ["title": "Newest", "serviceEndpoint": ["continuationCommand": ["token": "new-token"]]],
                ["title": "No token", "selected": false, "serviceEndpoint": ["continuationCommand": [:]]],
                ["selected": false, "serviceEndpoint": ["continuationCommand": ["token": "no-title"]]],
            ]]],
        ])])
        let p = CommentsParser.parse(Self.page(items: [], mutations: [], header: header))
        #expect(p.totalCountText == "1,234 Comments")
        #expect(p.sortOptions == [
            CommentSortOption(title: "Top", continuation: "top-token", isSelected: true),
            CommentSortOption(title: "Newest", continuation: "new-token", isSelected: false),
        ])
        #expect(p.comments.isEmpty); #expect(p.continuation == nil)
    }

    @Test func headerWithoutNumbersFallsBackToTheShortCount() throws {
        let withShort: JSON = .object(["commentsHeaderRenderer": .object([
            "countText": ["runs": [["text": "Comments"]]],
            "commentsCount": ["runs": [["text": "5.2K"]]],
        ])])
        #expect(CommentsParser.parse(Self.page(items: [], mutations: [], header: withShort)).totalCountText == "5.2K")
        let bare: JSON = .object(["commentsHeaderRenderer": .object(["countText": ["runs": [["text": "Comments"]]]])])
        #expect(CommentsParser.parse(Self.page(items: [], mutations: [], header: bare)).totalCountText == nil)
    }

    @Test func appendActionsAreReadLikeReloadCommands() throws {
        let append: JSON = .object([
            "onResponseReceivedEndpoints": [["appendContinuationItemsAction": [
                "continuationItems": .array([Self.thread(id: "A"), Self.continuation(token: "more")]),
            ]]],
            "frameworkUpdates": ["entityBatchUpdate": ["mutations": .array(Self.mutations(id: "A"))]],
        ])
        let p = CommentsParser.parse(append)
        #expect(p.comments.map(\.id) == ["A"]); #expect(p.continuation == "more")
        // Some endpoints report the same thing under onResponseReceivedActions.
        let actions: JSON = .object([
            "onResponseReceivedActions": [["appendContinuationItemsAction": [
                "continuationItems": .array([Self.thread(id: "A")]),
            ]]],
            "frameworkUpdates": ["entityBatchUpdate": ["mutations": .array(Self.mutations(id: "A"))]],
        ])
        #expect(CommentsParser.parse(actions).comments.map(\.id) == ["A"])
    }

    @Test func bareViewModelsAndThreadsMix() throws {
        // Replies pages hold bare commentViewModels (no thread wrapper); a double wrapper is tolerated too.
        let bare: JSON = .object(["commentViewModel": .object(["commentKey": "key-R", "toolbarStateKey": "toolbar-R", "commentId": "R"])])
        let wrapped: JSON = .object(["commentViewModel": .object(["commentViewModel": .object(["commentKey": "key-W", "toolbarStateKey": "toolbar-W", "commentId": "W"])])])
        let p = CommentsParser.parse(Self.page(
            items: [bare, wrapped, Self.thread(id: "T")],
            mutations: Self.mutations(id: "R") + Self.mutations(id: "W") + Self.mutations(id: "T")
        ))
        #expect(p.comments.map(\.id) == ["R", "W", "T"])
    }

    // MARK: - Garbage in, empty page out

    @Test(arguments: [
        "{}", "[]", "null", "\"x\"", "7",
        #"{"onResponseReceivedEndpoints":"x","frameworkUpdates":[]}"#,
        #"{"onResponseReceivedEndpoints":[1,null,"a",{}],"frameworkUpdates":{"entityBatchUpdate":{"mutations":"x"}}}"#,
        #"{"onResponseReceivedEndpoints":[{"reloadContinuationItemsCommand":{"continuationItems":"x"}},{"appendContinuationItemsAction":{}}]}"#,
        #"{"onResponseReceivedEndpoints":[{"appendContinuationItemsAction":{"continuationItems":[1,"a",null,{"commentThreadRenderer":5},{"commentThreadRenderer":{"commentViewModel":7}},{"commentViewModel":"x"}]}}]}"#,
    ])
    func unusableResponsesGiveAnEmptyPage(text: String) throws {
        let p = CommentsParser.parse(try JSON(data: Data(text.utf8)))
        #expect(p.comments.isEmpty); #expect(p.continuation == nil); #expect(p.totalCountText == nil); #expect(p.sortOptions.isEmpty)
    }

    @Test func aWatchPageIsNotACommentsPage() throws {
        let p = CommentsParser.parse(try Fixture.json("next_aqz.json"))
        #expect(p.comments.isEmpty)
    }

    @Test func mutationsWithoutKeysAreIgnored() throws {
        let odd: [JSON] = [
            .object(["payload": .object(["commentEntityPayload": .object(["properties": .object(["commentId": "A"])])])]),
            "not an object", .null, [], .object(["entityKey": 5]),
        ]
        let p = CommentsParser.parse(Self.page(items: [Self.thread(id: "A")], mutations: odd))
        #expect(p.comments.isEmpty)
    }

    // MARK: - Helpers

    private static func reload(_ items: [JSON], slot: String) -> JSON {
        .object(["reloadContinuationItemsCommand": .object([
            "continuationItems": .array(items), "slot": .string(slot), "targetId": "comments-section",
        ])])
    }

    /// A comments response: an optional header slot, a body slot with `items`, and the entity `mutations`.
    private static func page(items: [JSON], mutations: [JSON], header: JSON? = nil) -> JSON {
        var endpoints: [JSON] = []
        if let header { endpoints.append(reload([header], slot: "RELOAD_CONTINUATION_SLOT_HEADER")) }
        endpoints.append(reload(items, slot: "RELOAD_CONTINUATION_SLOT_BODY"))
        return .object([
            "onResponseReceivedEndpoints": .array(endpoints),
            "frameworkUpdates": .object(["entityBatchUpdate": .object(["mutations": .array(mutations)])]),
        ])
    }

    private static func continuation(token: String) -> JSON {
        .object(["continuationItemRenderer": .object([
            "continuationEndpoint": ["continuationCommand": ["token": .string(token)]],
        ])])
    }

    private static func continuationButton(token: String) -> JSON {
        .object(["continuationItemRenderer": .object([
            "button": ["buttonRenderer": ["command": ["continuationCommand": ["token": .string(token)]]]],
        ])])
    }

    /// A `commentThreadRenderer` whose view model points at the entities `mutations(id:)` produces.
    private static func thread(id: String, key: String? = nil, toolbarKey: String? = nil, pinned: Bool = false, repliesToken: String? = nil) -> JSON {
        var model: [String: JSON] = [
            "commentKey": .string(key ?? "key-\(id)"),
            "toolbarStateKey": .string(toolbarKey ?? "toolbar-\(id)"),
            "commentId": .string(id),
        ]
        if pinned { model["pinnedText"] = ["runs": [["text": "Pinned by @author"]]] }
        var renderer: [String: JSON] = ["commentViewModel": .object(["commentViewModel": .object(model)])]
        if let repliesToken {
            renderer["replies"] = ["commentRepliesRenderer": ["contents": .array([continuation(token: repliesToken)])]]
        }
        return .object(["commentThreadRenderer": .object(renderer)])
    }

    /// The comment entity and its toolbar-state entity, both as entity-batch mutations.
    private static func mutations(
        id: String, key: String? = nil, toolbarKey: String? = nil, text: String = "hello", author: String = "@author",
        published: String = "1 day ago", likes: JSON = "5", replies: JSON = "", creator: Bool = false, hearted: Bool = false
    ) -> [JSON] {
        let key = key ?? "key-\(id)"
        let toolbarKey = toolbarKey ?? "toolbar-\(id)"
        let comment: JSON = .object([
            "entityKey": .string(key),
            "payload": .object(["commentEntityPayload": .object([
                "key": .string(key),
                "properties": .object([
                    "commentId": .string(id),
                    "content": .object(["content": .string(text)]),
                    "publishedTime": .string(published),
                    "toolbarStateKey": .string(toolbarKey),
                ]),
                "author": .object([
                    "channelId": "UCauthor", "displayName": .string(author),
                    "avatarThumbnailUrl": "https://yt3.ggpht.com/a=s88", "isCreator": .bool(creator),
                ]),
                "toolbar": .object(["likeCountNotliked": likes, "replyCount": replies]),
            ])]),
        ])
        let state: JSON = .object([
            "entityKey": .string(toolbarKey),
            "payload": .object(["engagementToolbarStateEntityPayload": .object([
                "key": .string(toolbarKey),
                "heartState": .string(hearted ? "TOOLBAR_HEART_STATE_HEARTED" : "TOOLBAR_HEART_STATE_UNHEARTED"),
            ])]),
        ])
        return [comment, state]
    }

    /// `json` with the value at the dot-separated `path` (numbers index into arrays) replaced by `transform`'s
    /// result, or removed when it returns nil. A path that does not exist leaves `json` unchanged.
    private static func edited(_ json: JSON, _ path: String, _ transform: (JSON) -> JSON?) -> JSON {
        edit(json, path.split(separator: ".").map(String.init)[...], transform) ?? .null
    }

    private static func edit(_ json: JSON, _ steps: ArraySlice<String>, _ transform: (JSON) -> JSON?) -> JSON? {
        guard let step = steps.first else { return transform(json) }
        let rest = steps.dropFirst()
        switch json {
        case .object(var object):
            guard let child = object[step] else { return json }
            object[step] = edit(child, rest, transform)
            return .object(object)
        case .array(var array):
            guard let index = Int(step), array.indices.contains(index) else { return json }
            if let replaced = edit(array[index], rest, transform) {
                array[index] = replaced
            } else {
                array.remove(at: index)
            }
            return .array(array)
        default:
            return json
        }
    }
}
