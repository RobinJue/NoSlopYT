import Foundation
import Testing
@testable import NoSlopKit

/// Edits parsed JSON the way YouTube changing its mind would: deleting keys, renaming renderers, blanking subtrees.
/// Object keys are visited in sorted order, depth-first, which is the order of `JSON.findAll` / `JSON.first`.
enum BrowseJSONEdit {
    /// Removes `key` from every object that has it.
    static func removingEveryKey(_ key: String, in json: JSON) -> JSON {
        replacingValues(forKey: key, in: json, firstOnly: false) { _ in nil }
    }

    /// Removes `key` from `json` itself, not from anything nested in it (a renderer's own `videoId`, not the ones in
    /// its menus).
    static func removingDirectKey(_ key: String, in json: JSON) -> JSON {
        guard case .object(var object) = json else { return json }
        object.removeValue(forKey: key)
        return .object(object)
    }

    /// Replaces the value of `key` wherever it occurs. The transform sees the original value (nested matches
    /// inside it are not visited); returning nil removes the key.
    static func replacingEveryValue(forKey key: String, in json: JSON, _ transform: (JSON) -> JSON?) -> JSON {
        replacingValues(forKey: key, in: json, firstOnly: false, transform)
    }

    static func replacingFirstValue(forKey key: String, in json: JSON, _ transform: (JSON) -> JSON?) -> JSON {
        replacingValues(forKey: key, in: json, firstOnly: true, transform)
    }

    /// Renames every `key`, for "YouTube renamed the renderer".
    static func renamingEveryKey(_ key: String, to newKey: String, in json: JSON) -> JSON {
        switch json {
        case .array(let values):
            return .array(values.map { renamingEveryKey(key, to: newKey, in: $0) })
        case .object(let object):
            var result: [String: JSON] = [:]
            for (childKey, child) in object {
                result[childKey == key ? newKey : childKey] = renamingEveryKey(key, to: newKey, in: child)
            }
            return .object(result)
        default:
            return json
        }
    }

    /// Replaces every `modulo`-th node (counting depth-first from 0, the root excluded) with null.
    static func nullingNodes(in json: JSON, modulo: Int, remainder: Int) -> JSON {
        var counter = 0
        return nulling(json, modulo: modulo, remainder: remainder, counter: &counter)
    }

    // MARK: Implementation

    private static func replacingValues(forKey key: String, in json: JSON, firstOnly: Bool, _ transform: (JSON) -> JSON?) -> JSON {
        var done = false
        return rebuild(json, key: key, firstOnly: firstOnly, done: &done, transform)
    }

    private static func rebuild(_ json: JSON, key: String, firstOnly: Bool, done: inout Bool, _ transform: (JSON) -> JSON?) -> JSON {
        switch json {
        case .array(let values):
            var result: [JSON] = []
            for value in values {
                result.append(rebuild(value, key: key, firstOnly: firstOnly, done: &done, transform))
            }
            return .array(result)
        case .object(let object):
            var result: [String: JSON] = [:]
            for childKey in object.keys.sorted() {
                guard let child = object[childKey] else { continue }
                if childKey == key, !(firstOnly && done) {
                    done = true
                    if let replaced = transform(child) { result[childKey] = replaced }
                } else {
                    result[childKey] = rebuild(child, key: key, firstOnly: firstOnly, done: &done, transform)
                }
            }
            return .object(result)
        default:
            return json
        }
    }

    private static func nulling(_ json: JSON, modulo: Int, remainder: Int, counter: inout Int) -> JSON {
        switch json {
        case .array(let values):
            var result: [JSON] = []
            for value in values {
                counter += 1
                result.append(counter % modulo == remainder ? .null : nulling(value, modulo: modulo, remainder: remainder, counter: &counter))
            }
            return .array(result)
        case .object(let object):
            var result: [String: JSON] = [:]
            for childKey in object.keys.sorted() {
                guard let child = object[childKey] else { continue }
                counter += 1
                result[childKey] = counter % modulo == remainder ? .null : nulling(child, modulo: modulo, remainder: remainder, counter: &counter)
            }
            return .object(result)
        default:
            return json
        }
    }
}

@Suite struct ItemParserRobustnessTests {
    // MARK: From the plan (Review Focus 1)

    @Test func mutatedRenderersAreSkipped() throws {
        // Delete "videoId" from the first videoRenderer and "metadata" from the playlist lockup.
        var json = try Fixture.json("search_blender_tutorial.json")
        json = BrowseJSONEdit.replacingFirstValue(forKey: "videoRenderer", in: json) { renderer in
            BrowseJSONEdit.removingDirectKey("videoId", in: renderer)
        }
        json = BrowseJSONEdit.replacingFirstValue(forKey: "lockupViewModel", in: json) { lockup in
            BrowseJSONEdit.removingDirectKey("metadata", in: lockup)
        }
        // The edit really happened.
        #expect(json.first("videoRenderer")?["videoId"] == nil)
        #expect(json.first("lockupViewModel")?["metadata"] == nil)

        let p = SearchParser.parse(json)
        #expect(p.items.count >= 22)
        #expect(!p.items.contains { $0.video?.id == "z-Xl9tGqH14" })
        // Exactly those two items are gone; everything else is untouched.
        let original = SearchParser.parse(try Fixture.json("search_blender_tutorial.json"))
        #expect(p.items.count == 22)
        #expect(p.items == original.items.filter { $0.id != "video:z-Xl9tGqH14" && $0.id != "playlist:PLjEaoINr3zgEPv5y--4MKpciLaoQYZB1Z" })
        #expect(p.continuation == original.continuation)
    }

    @Test func emptyObjectYieldsEmptyPage() {
        #expect(SearchParser.parse([:]).items.isEmpty)
        #expect(ChannelParser.parseChannelPage([:]) == nil)
        #expect(RelatedParser.parse(next: [:]).items.isEmpty)
    }

    @Test func adsNeverReturned() throws {
        for name in ["search_blender_tutorial.json", "search_blender_tutorial_cont.json", "search_channels_only.json",
                     "search_playlists_only.json", "search_videos_only.json"] {
            let json = try Fixture.json(name)
            let page = SearchParser.parse(json)
            // Every identifier that appears anywhere under an ad slot.
            var adIDs = Set<String>()
            for slot in json.findAll("adSlotRenderer") {
                for key in ["videoId", "contentId", "channelId", "browseId", "playlistId"] {
                    adIDs.formUnion(slot.findAll(key).compactMap(\.string))
                }
            }
            let returned = Set(page.items.flatMap { item -> [String] in
                switch item {
                case .video(let video): [video.id, video.channel?.id].compactMap { $0 }
                case .channel(let channel): [channel.id]
                case .playlist(let playlist): [playlist.id, playlist.channel?.id].compactMap { $0 }
                }
            })
            #expect(returned.isDisjoint(with: adIDs), "\(name)")
            // The ad slots in these captures are there to be skipped (the continuation page has none).
            if name != "search_blender_tutorial_cont.json" {
                #expect(!json.findAll("adSlotRenderer").isEmpty, "\(name)")
            }
        }
    }

    // MARK: Ads and AI blocks, injected

    private static let adKeys = [
        "adSlotRenderer", "inFeedAdLayoutRenderer", "promotedVideoRenderer", "promotedSparklesWebRenderer", "searchPyvRenderer",
        "promotedSparklesTextSearchRenderer", "compactPromotedVideoRenderer", "displayAdRenderer",
    ]
    private static let aiKeys = ["videoSummaryContentViewModel", "genAiFeedbackFormViewModel"]

    private func realRenderers() throws -> (video: JSON, lockup: JSON, short: JSON, channel: JSON) {
        let search = try Fixture.json("search_blender_tutorial.json")
        return (
            video: try #require(search.first("videoRenderer")),
            lockup: try #require(search.first("lockupViewModel")),
            short: try #require(search.first("shortsLockupViewModel")),
            channel: try #require(search.first("channelRenderer"))
        )
    }

    @Test(arguments: adKeys + aiKeys)
    func nothingInsideAnAdOrAIBlockIsReturned(wrapper: String) throws {
        let real = try realRenderers()
        var payload: [String: JSON] = [:]
        payload["videoRenderer"] = real.video
        payload["lockupViewModel"] = real.lockup
        payload["shortsLockupViewModel"] = real.short
        payload["channelRenderer"] = real.channel

        // Directly inside the wrapper, and one level deeper (ad layouts nest their content).
        let direct = JSON.object([wrapper: .object(payload)])
        #expect(ItemParser.items(in: direct).isEmpty)
        let nested = JSON.object([wrapper: .object(["content": .object(["richItemRenderer": .object(["content": .object(payload)])])])])
        #expect(ItemParser.items(in: .array([nested])).isEmpty)

        // The same inside a search page.
        let section = JSON.object(["itemSectionRenderer": .object(["contents": .array([direct, nested])])])
        let page: JSON = ["contents": ["twoColumnSearchResultsRenderer": ["primaryContents": ["sectionListRenderer": ["contents": .array([section])]]]]]
        #expect(SearchParser.parse(page).items.isEmpty)
    }

    @Test(arguments: adKeys + aiKeys)
    func realItemsNextToAnAdAreStillReturned(wrapper: String) throws {
        let real = try realRenderers()
        let contents: JSON = [
            ["videoRenderer": real.video],
            [wrapper: ["videoRenderer": real.video]],
            ["lockupViewModel": real.lockup],
        ]
        let items = ItemParser.items(in: contents)
        #expect(items.map(\.id) == ["video:z-Xl9tGqH14", "playlist:PLjEaoINr3zgEPv5y--4MKpciLaoQYZB1Z"])
    }

    @Test func aiSummaryInsideAVideoRendererIsNotAnItem() throws {
        // In the captures the summary lives in videoRenderer.expandableMetadata; the video itself is still returned.
        let json = try Fixture.json("search_blender_tutorial.json")
        #expect(!json.findAll("videoSummaryContentViewModel").isEmpty)
        #expect(!json.findAll("genAiFeedbackFormViewModel").isEmpty)
        let page = SearchParser.parse(json)
        #expect(page.items.count == 24)
    }

    // MARK: Degenerate input

    @Test func nonObjectDocumentsYieldNothing() {
        let documents: [JSON] = [.null, [], "text", 42, true, ["a", "b"], [[], [:]], [:]]
        for document in documents {
            #expect(ItemParser.items(in: document).isEmpty)
            #expect(SearchParser.parse(document).items.isEmpty)
            #expect(SearchParser.parse(document).continuation == nil)
            #expect(ChannelParser.parseChannelPage(document) == nil)
            #expect(ChannelParser.parseTab(document).items.isEmpty)
            #expect(ChannelParser.parseContinuation(document).items.isEmpty)
            #expect(PlaylistParser.parse(document, playlistID: "PLx") == nil)
            #expect(PlaylistParser.parseContinuation(document).items.isEmpty)
            #expect(RelatedParser.parse(next: document).items.isEmpty)
            #expect(RelatedParser.parseContinuation(document).items.isEmpty)
        }
    }

    @Test func wrongTypesAreSkippedNotCrashed() throws {
        // Documents with the right keys holding the wrong kinds of values. None of them has anything to show.
        let empty = [
            #"{"contents":"text"}"#,
            #"{"contents":{"twoColumnSearchResultsRenderer":[1,2,3]}}"#,
            #"{"contents":{"twoColumnSearchResultsRenderer":{"primaryContents":{"sectionListRenderer":{"contents":"nope"}}}}}"#,
            #"{"contents":[{"videoRenderer":"nope"},{"videoRenderer":[1]},{"videoRenderer":{}},{"lockupViewModel":7},{"lockupViewModel":{}}]}"#,
            #"{"contents":[{"videoRenderer":{"videoId":5,"title":{"runs":[1,2]}}}]}"#,
            #"{"contents":[{"videoRenderer":{"videoId":"abc","title":{"runs":[{"text":1}]}}}]}"#,
            #"{"contents":[{"videoRenderer":{"videoId":"   ","title":{"simpleText":"t"}}}]}"#,
            #"{"contents":[{"videoRenderer":{"videoId":"abc","title":{"simpleText":"   "}}}]}"#,
            #"{"contents":[{"lockupViewModel":{"contentId":"abc","contentType":3,"metadata":{"lockupMetadataViewModel":"x"}}}]}"#,
            #"{"contents":[{"channelRenderer":{"channelId":["x"],"title":[]}}]}"#,
            #"{"contents":[{"shortsLockupViewModel":{"entityId":1,"onTap":"x","overlayMetadata":[]}}]}"#,
            #"{"contents":[{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":5}}}}]}"#,
            #"{"contents":[{"continuationItemRenderer":"x"},{"continuationItemViewModel":[]}]}"#,
            #"{"onResponseReceivedActions":"x"}"#,
            #"{"onResponseReceivedActions":[1,"x",{},{"appendContinuationItemsAction":1},{"appendContinuationItemsAction":{"continuationItems":"x"}}]}"#,
            #"{"header":{"pageHeaderRenderer":{"content":{"pageHeaderViewModel":"x"}}},"metadata":{"channelMetadataRenderer":5}}"#,
        ]
        for text in empty {
            let document = try JSON(data: Data(text.utf8))
            runEveryParser(on: document)
            #expect(ItemParser.items(in: document).isEmpty, "\(text)")
            #expect(SearchParser.parse(document).items.isEmpty, "\(text)")
            #expect(SearchParser.parse(document).continuation == nil, "\(text)")
            #expect(RelatedParser.parse(next: document).items.isEmpty, "\(text)")
            #expect(ChannelParser.parseTab(document).items.isEmpty, "\(text)")
        }

        // Sloppy but usable: a title that is a bare string, counts that are numbers, a missing thumbnail list.
        let usable = try JSON(data: Data(#"{"contents":[{"videoRenderer":{"videoId":"abc","title":"t","thumbnail":{"thumbnails":"x"},"lengthText":4,"viewCountText":[[]]}}]}"#.utf8))
        let video = try #require(ItemParser.items(in: usable).first?.video)
        #expect(video.id == "abc")
        #expect(video.title == "t")
        #expect(video.thumbnails.isEmpty)
        #expect(video.durationSeconds == nil)
        #expect(video.viewCount == nil)
    }

    @Test func veryDeepNestingIsFine() throws {
        // JSONSerialization allows 512 levels; the walkers recurse once per level.
        var text = #"{"videoRenderer":{"videoId":"abc","title":{"simpleText":"t"}}}"#
        for _ in 0..<200 { text = #"{"a":[\#(text)]}"# }
        let json = try JSON(data: Data(text.utf8))
        #expect(ItemParser.items(in: json).map(\.id) == ["video:abc"])
        #expect(SearchParser.parse(json).items.isEmpty)
        runEveryParser(on: json)
    }

    // MARK: Whole-fixture sweeps

    private static let browseFixtures = [
        "search_blender_tutorial.json", "search_blender_tutorial_cont.json", "search_channels_only.json",
        "search_playlists_only.json", "search_videos_only.json", "channel_blender_home.json", "channel_blender_live.json",
        "channel_blender_playlists.json", "channel_blender_shorts.json", "channel_blender_videos.json",
        "channel_blender_videos_cont.json", "playlist_sample.json", "next_aqz.json", "next_aqz_related_cont.json",
        "next_rickroll.json", "next_with_chapters.json", "browse_home_anon.json",
    ]

    /// Responses that carry no search results, channel or playlist at all.
    private static let unrelatedFixtures = [
        "player_ios_sabr_only.json", "player_visionos_bigbuckbunny.json", "player_visionos_rickroll.json",
        "comments_aqz.json", "comments_aqz_cont.json", "resolve_handle.json", "visitor_id.json",
        "dearrow_prefix.json", "sponsorblock_prefix.json", "suggest_firefox.json",
    ]

    private func runEveryParser(on json: JSON) {
        _ = ItemParser.items(in: json)
        _ = SearchParser.parse(json)
        _ = ChannelParser.parseChannelPage(json)
        _ = ChannelParser.parseTab(json)
        _ = ChannelParser.parseContinuation(json)
        _ = PlaylistParser.parse(json, playlistID: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        _ = PlaylistParser.parseContinuation(json)
        _ = RelatedParser.parse(next: json)
        _ = RelatedParser.parseContinuation(json)
    }

    @Test(arguments: browseFixtures)
    func everyParserSurvivesEveryBrowseFixture(name: String) async throws {
        try await heavyWork {
            runEveryParser(on: try Fixture.json(name))
        }
    }

    @Test(arguments: unrelatedFixtures)
    func unrelatedResponsesYieldNothing(name: String) throws {
        let json = try Fixture.json(name)
        #expect(ItemParser.items(in: json).isEmpty, "\(name)")
        #expect(SearchParser.parse(json).items.isEmpty, "\(name)")
        #expect(ChannelParser.parseChannelPage(json) == nil, "\(name)")
        #expect(ChannelParser.parseTab(json).items.isEmpty, "\(name)")
        #expect(ChannelParser.parseContinuation(json).items.isEmpty, "\(name)")
        #expect(PlaylistParser.parse(json, playlistID: "PLx") == nil, "\(name)")
        #expect(PlaylistParser.parseContinuation(json).items.isEmpty, "\(name)")
        #expect(RelatedParser.parse(next: json).items.isEmpty, "\(name)")
        #expect(RelatedParser.parseContinuation(json).items.isEmpty, "\(name)")
    }

    // MARK: YouTube changes shapes

    @Test func aRenamedRendererLosesOnlyItsOwnItems() throws {
        let json = try Fixture.json("search_blender_tutorial.json")
        let original = SearchParser.parse(json)

        let noVideos = SearchParser.parse(BrowseJSONEdit.renamingEveryKey("videoRenderer", to: "videoRendererV2", in: json))
        #expect(noVideos.items.compactMap(\.video).count == 5)   // only the Shorts shelf is left
        #expect(noVideos.items.count == 7)
        #expect(noVideos.continuation == original.continuation)

        let noShelf = SearchParser.parse(BrowseJSONEdit.renamingEveryKey("shortsLockupViewModel", to: "shortsLockupViewModelV2", in: json))
        #expect(noShelf.items.count == 19)
        #expect(noShelf.items == original.items.filter { !["gIjBeEvDXew", "w29pAeH_xvU", "13PdfUES_lw", "XplZvYsRNSU", "a1OIIMqWC6M"].contains($0.video?.id ?? "") })

        let noWrapper = SearchParser.parse(BrowseJSONEdit.renamingEveryKey("itemSectionRenderer", to: "itemSectionRendererV2", in: json))
        // The harvest does not depend on the wrapper's name; only the continuation could be lost, and it is not.
        #expect(noWrapper.items == original.items)
        #expect(noWrapper.continuation == original.continuation)
    }

    @Test func aMissingPageScopeFallsBackToTheWholeContentsTree() throws {
        let json = try Fixture.json("search_blender_tutorial.json")
        let original = SearchParser.parse(json)
        let renamed = BrowseJSONEdit.renamingEveryKey("twoColumnSearchResultsRenderer", to: "threeColumnSearchResultsRenderer", in: json)
        #expect(SearchParser.parse(renamed).items == original.items)
        #expect(SearchParser.parse(renamed).continuation == original.continuation)
    }

    @Test func missingFieldsDegradeTheItemNotThePage() throws {
        let json = try Fixture.json("search_videos_only.json")
        let original = SearchParser.parse(json)
        #expect(original.items.count == 20)
        // Without a title nothing can be shown; without everything else the video is still there.
        #expect(SearchParser.parse(BrowseJSONEdit.removingEveryKey("title", in: json)).items.compactMap(\.video).isEmpty)
        for key in ["thumbnail", "lengthText", "viewCountText", "publishedTimeText", "ownerText", "longBylineText", "shortBylineText",
                    "channelThumbnailSupportedRenderers", "navigationEndpoint", "badges", "ownerBadges", "thumbnailOverlays"] {
            let page = SearchParser.parse(BrowseJSONEdit.removingEveryKey(key, in: json))
            #expect(page.items.count == 20, "without \(key)")
            #expect(page.items.map(\.id) == original.items.map(\.id), "without \(key)")
        }
    }

    @Test(arguments: browseFixtures)
    func blankedSubtreesNeverCrashAndNeverAddItems(name: String) async throws {
        let counts = try await heavyWork {
            let json = try Fixture.json(name)
            let baseline = ItemParser.items(in: json).count
            return [(7, 3), (19, 0), (43, 11)].map { modulo, remainder -> (baseline: Int, damaged: Int, label: String) in
                let damaged = BrowseJSONEdit.nullingNodes(in: json, modulo: modulo, remainder: remainder)
                runEveryParser(on: damaged)
                return (baseline, ItemParser.items(in: damaged).count, "\(name) \(modulo)/\(remainder)")
            }
        }
        for count in counts {
            #expect(count.damaged <= count.baseline, "\(count.label)")
        }
    }

    // MARK: Shorts

    @Test func shortsAreFlaggedWhateverTheRendererIs() throws {
        let search = SearchParser.parse(try Fixture.json("search_blender_tutorial_cont.json"))
        let shorts = search.items.compactMap(\.video).filter(\.isShort)
        #expect(shorts.count == 12)
        let all = ItemParser.items(in: try Fixture.json("channel_blender_shorts.json"))
        #expect(all.compactMap(\.video).count == 35)
        #expect(all.compactMap(\.video).allSatisfy { $0.isShort })
    }
}
