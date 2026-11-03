import Foundation
import Testing
@testable import NoSlopKit

@Suite struct WatchMetadataParserTests {
    // MARK: - Real responses (plan tests)

    @Test func bigBuckBunnyMetadata() throws {
        let json = try Fixture.json("next_aqz.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "aqz-KE-bpKQ"))
        #expect(d.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(d.viewCountText == "23,500,582 views"); #expect(d.viewCount == 23_500_582); #expect(d.shortViewCountText == "23M views")
        #expect(d.dateText == "Nov 10, 2014"); #expect(d.relativeDateText == "11 years ago")
        #expect(d.channel.name == "Blender"); #expect(d.channel.id == "UCSMOQeBJ2RAnuFungnQOxLg"); #expect(d.channel.avatarURL != nil)
        #expect(d.subscriberCountText == "1.25M subscribers"); #expect(d.likeCountText == "110K"); #expect(d.likeCount != nil)
        #expect(d.description.text.hasPrefix("UHD High Frame rate version of the iconic short film by Blender, Big B"))
        #expect(d.description.text.utf16.count == 219); #expect(d.description.links.count == 2)
        let link = try #require(d.description.links.first)
        #expect(link.range == 93..<133)
        guard case .url(let u) = link.target else { Issue.record("expected url"); return }
        #expect(u.host != "www.youtube.com")                // /redirect?…&q=<real> is unwrapped
        #expect(d.commentsContinuation != nil); #expect(d.chapters.isEmpty); #expect(!d.isLive); #expect(d.related.isEmpty)
    }

    @Test func rickrollLinks() throws {
        let json = try Fixture.json("next_rickroll.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "dQw4w9WgXcQ"))
        #expect(d.title == "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)"); #expect(d.viewCountText == "1,833,297,545 views")
        #expect(d.description.links.count == 16)
        let first = try #require(d.description.links.first); #expect(first.range == 180..<196)
        #expect(first.target == .hashtag("rickastleynever"))
        let u16 = Array(d.description.text.utf16)
        #expect(String(utf16CodeUnits: Array(u16[first.range]), count: 16).hasPrefix("#"))
    }

    @Test func chapters() throws {
        let json = try Fixture.json("next_with_chapters.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "z-Xl9tGqH14"))
        #expect(d.chapters.count == 8)
        let first = try #require(d.chapters.first)
        #expect(first == Chapter(title: "Part 1 The Basics", startSeconds: 0, thumbnailURL: first.thumbnailURL))
        let second = try #require(d.chapters.dropFirst().first)
        #expect(second.title == "Part 2 Basic Modelling"); #expect(second.startSeconds == 1696)
    }

    @Test func minimalNextStillParses() throws {
        let json = try JSON(data: Data(#"{"contents":{"twoColumnWatchNextResults":{"results":{"results":{"contents":[{"videoPrimaryInfoRenderer":{"title":{"runs":[{"text":"T"}]}}}]}}}}}"#.utf8))
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.id == "abc"); #expect(d.title == "T"); #expect(d.channel.name == ""); #expect(d.channel.id == "")
        #expect(d.channel.avatarURL == nil); #expect(d.channel.handle == nil)
        #expect(d.viewCount == nil); #expect(d.viewCountText == nil); #expect(d.shortViewCountText == nil)
        #expect(d.dateText == nil); #expect(d.relativeDateText == nil)
        #expect(d.likeCount == nil); #expect(d.likeCountText == nil); #expect(d.subscriberCountText == nil)
        #expect(d.description == .empty); #expect(d.chapters.isEmpty)
        #expect(d.commentCountText == nil); #expect(d.commentsContinuation == nil)
        #expect(d.related.isEmpty); #expect(d.relatedContinuation == nil); #expect(!d.isLive)
    }

    // MARK: - Real responses (fields)

    @Test func rickrollMetadata() throws {
        let json = try Fixture.json("next_rickroll.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "dQw4w9WgXcQ"))
        #expect(d.viewCount == 1_833_297_545)
        // This response has `extraShortViewCount` ("1.8B", no unit) but no `shortViewCount`: don't show a bare number.
        #expect(d.shortViewCountText == nil)
        #expect(d.dateText == "Oct 24, 2009"); #expect(d.relativeDateText == "17 years ago")
        #expect(d.channel.name == "Rick Astley"); #expect(d.channel.id == "UCuAXFkgsw1L7xaCfnd5JJOw")
        // The title run links to /channel/UC…; the handle comes from the owner's own navigation endpoint.
        #expect(d.channel.handle == "@RickAstleyYT")
        #expect(d.subscriberCountText == "4.56M subscribers")
        #expect(d.likeCountText == "19M"); #expect(d.likeCount == 19_493_775)
        #expect(d.commentCountText == "2.4M"); #expect(d.commentsContinuation != nil)
        #expect(d.chapters.isEmpty); #expect(!d.isLive)
    }

    @Test func bigBuckBunnyHandleLikesAndCommentTeaser() throws {
        let json = try Fixture.json("next_aqz.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "aqz-KE-bpKQ"))
        #expect(d.channel.handle == "@BlenderOfficial")
        #expect(d.likeCount == 110_320)                      // exact number from the button's accessibility text
        #expect(d.commentCountText == "5.2K")                // the comments panel header, not the "Comments" heading
        let token = try #require(d.commentsContinuation)
        #expect(token.hasPrefix("Eg0SC2Fxei1LRS1icEtRGAYyJSIR"))   // the in-page comments section, not the engagement panel
        #expect(d.summary.title == d.title); #expect(d.summary.channel == d.channel); #expect(d.summary.publishedText == "11 years ago")
    }

    @Test func tutorialMetadata() throws {
        let json = try Fixture.json("next_with_chapters.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "z-Xl9tGqH14"))
        #expect(d.title == "Beginner Blender Tutorial (2026)")
        #expect(d.viewCountText == "2,763,868 views"); #expect(d.viewCount == 2_763_868); #expect(d.shortViewCountText == "2.7M views")
        #expect(d.dateText == "Jan 14, 2026"); #expect(d.relativeDateText == "9 months ago")
        #expect(d.channel.name == "Blender Guru"); #expect(d.channel.id == "UCOKHwx1VCdgnxwbjyb9Iu1g"); #expect(d.channel.handle == "@blenderguru")
        #expect(d.subscriberCountText == "3.45M subscribers")
        #expect(d.likeCountText == "71K"); #expect(d.likeCount == 71_083)
        #expect(d.commentCountText == "3.6K")
    }

    @Test func channelAvatarIsTheLargestRendition() throws {
        let json = try Fixture.json("next_aqz.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "aqz-KE-bpKQ"))
        let avatar = try #require(d.channel.avatarURL)
        #expect(avatar.absoluteString.contains("=s176-"))
    }

    // MARK: - Channel (synthetic)

    @Test func channelIdAndHandleFallBackToTheTitleRun() throws {
        let d = try Self.details(owner: [
            "title": ["runs": [["text": "Run Name", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCrun", "canonicalBaseUrl": "/@RunHandle"]]]]],
        ])
        #expect(d.channel.name == "Run Name"); #expect(d.channel.id == "UCrun"); #expect(d.channel.handle == "@RunHandle")
    }

    @Test func handleIsOnlyTakenFromAnAtUrl() throws {
        // The owner endpoint has a /channel/ URL, so the title run's "/@…" URL supplies the handle.
        let both = try Self.details(owner: [
            "title": ["runs": [["text": "N", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCown", "canonicalBaseUrl": "/@Fallback"]]]]],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "UCown", "canonicalBaseUrl": "/channel/UCown"]],
        ])
        #expect(both.channel.id == "UCown"); #expect(both.channel.handle == "@Fallback")

        let none = try Self.details(owner: [
            "title": ["runs": [["text": "N"]]],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "UCown", "canonicalBaseUrl": "/c/LegacyName"]],
        ])
        #expect(none.channel.id == "UCown"); #expect(none.channel.handle == nil)

        let encoded = try Self.details(owner: [
            "title": ["runs": [["text": "N"]]],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "UCown", "canonicalBaseUrl": "/@%E3%83%86%E3%82%B9%E3%83%88"]],
        ])
        #expect(encoded.channel.handle == "@\u{30C6}\u{30B9}\u{30C8}")
    }

    @Test func collaborationOwnerHasNoChannelIdButAName() throws {
        let d = try Self.details(owner: [
            "title": ["runs": [["text": "Alice"], ["text": " and "], ["text": "Bob"]]],
            "navigationEndpoint": ["showDialogCommand": ["panelLoadingStrategy": "x"]],
            "subscriberCountText": ["simpleText": "2 channels"],
        ])
        #expect(d.channel.name == "Alice and Bob"); #expect(d.channel.id == ""); #expect(d.channel.handle == nil)
        #expect(d.subscriberCountText == "2 channels")
    }

    @Test func chaptersAreOrderedAndCarryTheirLargestThumbnail() throws {
        let json = try Fixture.json("next_with_chapters.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "z-Xl9tGqH14"))
        #expect(d.chapters.map(\.startSeconds) == [0, 1696, 3545, 5413, 7426, 9340, 11366, 13571])
        #expect(d.chapters.map(\.title) == [
            "Part 1 The Basics", "Part 2 Basic Modelling", "Part 3 Organic Modelling", "Part 4 Materials",
            "Part 5 Texturing", "Part 6 UV Unwrapping", "Part 7 Scattering", "Part 8 Lighting and Rendering",
        ])
        let renderer = try #require(json.first("chapterRenderer"))
        let largest = try #require(renderer["thumbnail"]?["thumbnails"]?.array?.last?["url"]?.string)
        #expect(d.chapters.first?.thumbnailURL?.absoluteString == largest)
        #expect(d.chapters.allSatisfy { $0.thumbnailURL != nil })
    }

    // MARK: - Description links (real response)

    @Test func tutorialDescriptionLinks() throws {
        let json = try Fixture.json("next_with_chapters.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "z-Xl9tGqH14"))
        #expect(d.description.links.count == 16)
        let units = Array(d.description.text.utf16)
        func text(of link: DescriptionLink) -> String { String(decoding: units[link.range], as: UTF16.self) }

        var timestamps: [(text: String, seconds: Int)] = []
        var hashtags: [(text: String, tag: String)] = []
        var urls: [URL] = []
        for link in d.description.links {
            switch link.target {
            case .timestamp(let seconds): timestamps.append((text(of: link), seconds))
            case .hashtag(let tag): hashtags.append((text(of: link), tag))
            case .url(let url): urls.append(url)
            default: Issue.record("unexpected target \(link.target)")
            }
        }
        // `0:00` has no startTimeSeconds in the response and means the start of the video.
        #expect(timestamps.map(\.seconds) == [0, 1696, 3545, 5413, 7426, 9340, 11366, 13571])
        #expect(timestamps.map(\.text) == ["0:00", "28:16", "59:05", "1:30:13", "2:03:46", "2:35:40", "3:09:26", "3:46:11"])
        #expect(hashtags.map(\.tag) == ["dellpromaxdell", "nvidia"])
        #expect(hashtags.map(\.text) == ["#DellProMaxDell", "#Nvidia"])
        #expect(urls.map(\.absoluteString) == [
            "https://www.blenderguru.com/academy",
            "https://www.blenderguru.com/posts/blender-donut-v5-tutorial",
            "http://www.poliigon.com/",
            "https://twitter.com/andrewpprice",
            "http://instagram.com/andrewpprice",
            "http://artstation.com/artist/andrewprice",
        ])
    }

    @Test func rickrollLinkRangesSurviveEmojiInTheText() throws {
        let json = try Fixture.json("next_rickroll.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "dQw4w9WgXcQ"))
        // The text holds non-BMP and variation-selector characters, so UTF-16 offsets differ from character offsets.
        #expect(d.description.text.utf16.count != d.description.text.count)
        let units = Array(d.description.text.utf16)
        var previousEnd = 0
        var hashtags = 0
        var urls = 0
        for link in d.description.links {
            #expect(link.range.lowerBound >= previousEnd && link.range.upperBound <= units.count)
            previousEnd = link.range.upperBound
            let shown = String(decoding: units[link.range], as: UTF16.self)
            switch link.target {
            case .hashtag(let tag):
                hashtags += 1
                #expect(shown.hasPrefix("#") && shown.dropFirst().lowercased() == tag)
            case .url(let url):
                urls += 1
                #expect(shown == url.absoluteString)        // every link in this description shows its real address
            default:
                Issue.record("unexpected target \(link.target)")
            }
        }
        #expect(hashtags == 5); #expect(urls == 11)
    }

    // MARK: - Description link targets (synthetic)

    @Test func descriptionTargetsFromEveryEndpointKind() throws {
        let content = "see 0:30 here, https://a.example/x and #Swift, @chan, list, other, bad"
        func range(of word: String) -> (Int, Int) {
            let r = content.range(of: word)!
            return (content.utf16.distance(from: content.startIndex, to: r.lowerBound), word.utf16.count)
        }
        func run(_ word: String, _ endpoint: String, _ payload: JSON) -> JSON {
            let (start, length) = range(of: word)
            return .object([
                "startIndex": .number(Double(start)), "length": .number(Double(length)),
                "onTap": .object(["innertubeCommand": .object([endpoint: payload])]),
            ])
        }
        let runs: [JSON] = [
            run("0:30", "watchEndpoint", ["videoId": "abc", "startTimeSeconds": 30]),
            run("https://a.example/x", "urlEndpoint", ["url": "https://www.youtube.com/redirect?event=video_description&q=https%3A%2F%2Fa.example%2Fx%3Fa%3D1%26b%3D2&v=abc"]),
            run("#Swift", "urlEndpoint", ["url": "/hashtag/swift"]),
            run("@chan", "browseEndpoint", ["browseId": "UCabcdefghijklmnopqrstuv"]),
            run("list", "browseEndpoint", ["browseId": "VLPLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"]),
            run("other", "watchEndpoint", ["videoId": "zzz", "startTimeSeconds": 12]),
            run("bad", "signInEndpoint", ["x": 1]),
        ]
        let d = try #require(WatchMetadataParser.parse(Self.next(description: content, runs: runs), videoID: "abc"))
        let unwrapped = try #require(URL(string: "https://a.example/x?a=1&b=2"))
        let targets = d.description.links.map(\.target)
        #expect(targets == [
            .timestamp(seconds: 30),
            .url(unwrapped),
            .hashtag("swift"),
            .channel(id: "UCabcdefghijklmnopqrstuv"),
            .playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"),
            .video(id: "zzz", startSeconds: 12),
        ])
    }

    @Test func watchLinkToAnotherVideoWithoutTimeHasNoStart() throws {
        let content = "next video"
        let run: JSON = .object([
            "startIndex": 0, "length": 10,
            "onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": "zzz", "playlistId": "PLx"]]],
        ])
        let d = try #require(WatchMetadataParser.parse(Self.next(description: content, runs: [run]), videoID: "abc"))
        #expect(d.description.links == [DescriptionLink(range: 0..<10, target: .video(id: "zzz", startSeconds: nil))])
    }

    @Test func timestampOfTheSameVideoWithoutStartIsZero() throws {
        let run: JSON = .object([
            "startIndex": 0, "length": 4,
            "onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": "abc"]]],
        ])
        let d = try #require(WatchMetadataParser.parse(Self.next(description: "0:00 intro", runs: [run]), videoID: "abc"))
        #expect(d.description.links == [DescriptionLink(range: 0..<4, target: .timestamp(seconds: 0))])
    }

    @Test func runWithoutStartIndexStartsAtZero() throws {
        // Protobuf-style JSON omits zero values.
        let run: JSON = .object([
            "length": 4,
            "onTap": ["innertubeCommand": ["urlEndpoint": ["url": "https://example.com/"]]],
        ])
        let d = try #require(WatchMetadataParser.parse(Self.next(description: "link text", runs: [run]), videoID: "abc"))
        #expect(d.description.links.map(\.range) == [0..<4])
    }

    @Test func hashtagCommandFallsBackToTheVisibleText() throws {
        let run: JSON = .object([
            "startIndex": 0, "length": 8,
            "onTap": ["innertubeCommand": ["browseEndpoint": ["browseId": "FEhashtag", "params": "x"]]],
        ])
        let d = try #require(WatchMetadataParser.parse(Self.next(description: "#SwiftUI rocks", runs: [run]), videoID: "abc"))
        #expect(d.description.links == [DescriptionLink(range: 0..<8, target: .hashtag("swiftui"))])
    }

    @Test func percentEncodedHashtagIsDecoded() throws {
        let run: JSON = .object([
            "startIndex": 0, "length": 4,
            "onTap": ["innertubeCommand": [
                "commandMetadata": ["webCommandMetadata": ["url": "/hashtag/%E3%83%86%E3%82%B9%E3%83%88"]],
                "browseEndpoint": ["browseId": "FEhashtag", "params": "x"],
            ]],
        ])
        let d = try #require(WatchMetadataParser.parse(Self.next(description: "#\u{30C6}\u{30B9}\u{30C8} x", runs: [run]), videoID: "abc"))
        #expect(d.description.links.first?.target == .hashtag("\u{30C6}\u{30B9}\u{30C8}"))
    }

    @Test func redirectWithoutTargetKeepsTheOriginalLink() throws {
        let original = "https://www.youtube.com/redirect?event=video_description&redir_token=abc"
        let run: JSON = .object([
            "startIndex": 0, "length": 4,
            "onTap": ["innertubeCommand": ["urlEndpoint": ["url": .string(original)]]],
        ])
        let d = try #require(WatchMetadataParser.parse(Self.next(description: "link", runs: [run]), videoID: "abc"))
        #expect(d.description.links.first?.target == .url(try #require(URL(string: original))))
    }

    @Test(arguments: [
        "javascript:alert(1)",
        "intent://scan/#Intent;scheme=zxing;end",
        "mailto:someone@example.com",
        "",
        "not a url at all",
        "https://www.youtube.com/redirect?q=javascript%3Aalert(1)",
    ])
    func nonWebLinksAreDropped(url: String) throws {
        let run: JSON = .object([
            "startIndex": 0, "length": 4,
            "onTap": ["innertubeCommand": ["urlEndpoint": ["url": .string(url)]]],
        ])
        let d = try #require(WatchMetadataParser.parse(Self.next(description: "link", runs: [run]), videoID: "abc"))
        #expect(d.description.links.isEmpty)
        #expect(d.description.text == "link")
    }

    @Test func linksUseUTF16OffsetsAfterEmoji() throws {
        // U+1F600 is two UTF-16 units: "link" starts at offset 3, not 2.
        let content = "\u{1F600} link here"
        let run: JSON = .object([
            "startIndex": 3, "length": 4,
            "onTap": ["innertubeCommand": ["urlEndpoint": ["url": "https://example.com/"]]],
        ])
        let d = try #require(WatchMetadataParser.parse(Self.next(description: content, runs: [run]), videoID: "abc"))
        let link = try #require(d.description.links.first)
        #expect(link.range == 3..<7)
        #expect(String(decoding: Array(d.description.text.utf16)[link.range], as: UTF16.self) == "link")
    }

    @Test func invalidRunsAreSkippedAndTheRestKept() throws {
        let content = "0123456789"
        func url(_ start: JSON?, _ length: JSON?) -> JSON {
            var object: [String: JSON] = ["onTap": ["innertubeCommand": ["urlEndpoint": ["url": "https://example.com/"]]]]
            if let start { object["startIndex"] = start }
            if let length { object["length"] = length }
            return .object(object)
        }
        let runs: [JSON] = [
            url(2, 3),                       // valid: 2..<5
            url(-1, 3),                      // negative start
            url(4, 0),                       // empty
            url(4, -2),                      // negative length
            url(8, 5),                       // runs past the end
            url(20, 2),                      // starts past the end
            url(.string("x"), 2),            // not a number
            url(5, nil),                     // no length
            url(6, 4),                       // valid: 6..<10 (ends exactly at the end)
        ]
        let d = try #require(WatchMetadataParser.parse(Self.next(description: content, runs: runs), videoID: "abc"))
        #expect(d.description.links.map(\.range) == [2..<5, 6..<10])
    }

    @Test func descriptionWithoutRunsIsPlainText() throws {
        let d = try #require(WatchMetadataParser.parse(Self.next(description: "just text", runs: []), videoID: "abc"))
        #expect(d.description == AttributedDescription(text: "just text", links: []))
    }

    @Test func plainDescriptionIsUsedWhenThereIsNoAttributedOne() throws {
        let json = try JSON(data: Data(#"""
        {"contents":{"twoColumnWatchNextResults":{"results":{"results":{"contents":[
          {"videoPrimaryInfoRenderer":{"title":{"simpleText":"T"}}},
          {"videoSecondaryInfoRenderer":{"description":{"runs":[{"text":"old "},{"text":"style"}]}}}
        ]}}}}}
        """#.utf8))
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.description == AttributedDescription(text: "old style", links: []))
    }

    // MARK: - Chapters (synthetic)

    @Test func descriptionChaptersWinOverAutoChapters() throws {
        let json = Self.next(chapters: [
            ("AUTO_CHAPTERS", [("Auto", 0)]),
            ("DESCRIPTION_CHAPTERS", [("Intro", 0), ("Main", 30_000)]),
        ])
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.chapters.map(\.title) == ["Intro", "Main"])
        #expect(d.chapters.map(\.startSeconds) == [0, 30])
    }

    @Test func autoChaptersAreUsedWhenThereAreNoDescriptionChapters() throws {
        let json = Self.next(chapters: [
            ("HEATSEEKER", [("not a chapter", 0)]),
            ("AUTO_CHAPTERS", [("Auto one", 0), ("Auto two", 61_500)]),
        ])
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.chapters.map(\.title) == ["Auto one", "Auto two"])
        #expect(d.chapters.map(\.startSeconds) == [0, 61.5])
    }

    @Test func chaptersAreSortedAndBrokenOnesDropped() throws {
        let json = try JSON(data: Data(#"""
        {"contents":{"twoColumnWatchNextResults":{"results":{"results":{"contents":[
          {"videoPrimaryInfoRenderer":{"title":{"simpleText":"T"}}}]}}}},
         "playerOverlays":{"playerOverlayRenderer":{"decoratedPlayerBarRenderer":{"decoratedPlayerBarRenderer":{"playerBar":{
           "multiMarkersPlayerBarRenderer":{"markersMap":[{"key":"DESCRIPTION_CHAPTERS","value":{"chapters":[
             {"chapterRenderer":{"title":{"simpleText":"Second"},"timeRangeStartMillis":20000}},
             {"chapterRenderer":{"title":{"simpleText":"First"},"timeRangeStartMillis":0}},
             {"chapterRenderer":{"title":{"simpleText":"No time"}}},
             {"chapterRenderer":{"timeRangeStartMillis":5000}},
             {"chapterRenderer":{"title":{"simpleText":"Negative"},"timeRangeStartMillis":-1000}},
             {"somethingElse":{}}
           ]}}]}}}}}}}
        """#.utf8))
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.chapters.map(\.title) == ["First", "Second"])
        #expect(d.chapters.map(\.startSeconds) == [0, 20])
        #expect(d.chapters.allSatisfy { $0.thumbnailURL == nil })
    }

    // MARK: - Counts, likes and live (synthetic)

    @Test func liveStreamIsFlagged() throws {
        let json = try JSON(data: Data(#"""
        {"contents":{"twoColumnWatchNextResults":{"results":{"results":{"contents":[
          {"videoPrimaryInfoRenderer":{"title":{"simpleText":"Live now"},
            "viewCount":{"videoViewCountRenderer":{"viewCount":{"runs":[{"text":"1,234"},{"text":" watching now"}]},"isLive":true}},
            "dateText":{"simpleText":"Started streaming 2 hours ago"}}}]}}}}}
        """#.utf8))
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.isLive); #expect(d.summary.isLive)
        #expect(d.viewCountText == "1,234 watching now")
        #expect(d.dateText == "Started streaming 2 hours ago")
    }

    @Test func hiddenLikeCountGivesNoCount() throws {
        let json = Self.next(likeTitle: "Like", likeAccessibility: "like this video")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.likeCountText == nil); #expect(d.likeCount == nil)
    }

    @Test func likeCountFallsBackToTheRoundedTitle() throws {
        // The accessibility text disagrees with the title (a different sentence): trust the title.
        let json = Self.next(likeTitle: "110K", likeAccessibility: "like this video along with 3 friends")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.likeCountText == "110K"); #expect(d.likeCount == 110_000)
    }

    @Test func likeCountWithoutAccessibilityTextUsesTheTitle() throws {
        let json = Self.next(likeTitle: "1.2M", likeAccessibility: nil)
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.likeCountText == "1.2M"); #expect(d.likeCount == 1_200_000)
    }

    @Test func exactLikeCountAgreesWithTheRoundedTitle() throws {
        let json = Self.next(likeTitle: "1.2M", likeAccessibility: "like this video along with 1,203,456 other people")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.likeCount == 1_203_456)
    }

    /// What the page said in some language, and the numbers the parser may derive from it.
    struct LocalizedCounts: Sendable, CustomTestStringConvertible {
        var views: String
        var viewCount: Int?
        var like: String
        var likeAccessibility: String?
        var likeCount: Int?
        var subscribers: String

        var testDescription: String { "\(views) | \(like) | \(subscribers)" }
    }

    private static let localizedCounts: [LocalizedCounts] = [
        // English: numbers for everything, the exact like count from the accessibility text.
        LocalizedCounts(
            views: "23,500,582 views", viewCount: 23_500_582, like: "110K",
            likeAccessibility: "like this video along with 110,320 other people", likeCount: 110_320, subscribers: "1.25M subscribers"
        ),
        // German: the units Tsd., Mio. and the grouping dots are understood; the exact count agrees with the rounded one.
        LocalizedCounts(
            views: "2.763.792 Aufrufe", viewCount: 2_763_792, like: "110 Tsd.",
            likeAccessibility: "Mit „Gefällt mir“ bewerten – zusammen mit 110.123 anderen Personen", likeCount: 110_123,
            subscribers: "1,25 Mio. Abonnenten"
        ),
        LocalizedCounts(views: "12 Aufrufe", viewCount: 12, like: "9,8 Tsd.", likeAccessibility: nil, likeCount: 9_800, subscribers: "110 Tsd. Abonnenten"),
        // Units the parser does not know: no number, and the text YouTube sent is still there.
        LocalizedCounts(views: "12万 回視聴", viewCount: nil, like: "12万", likeAccessibility: nil, likeCount: nil, subscribers: "チャンネル登録者数 125万人"),
        LocalizedCounts(
            views: "12 тыс. просмотров", viewCount: nil, like: "12 тыс.", likeAccessibility: "Нравится: 12 тыс.", likeCount: nil,
            subscribers: "1,25 млн подписчиков"
        ),
        LocalizedCounts(views: "12 tn visningar", viewCount: nil, like: "12 tn", likeAccessibility: nil, likeCount: nil, subscribers: "1,25 mn prenumeranter"),
        // A French page: the grouped view count is read, the abbreviated like count is not.
        LocalizedCounts(views: "2 763 792 vues", viewCount: 2_763_792, like: "12 k", likeAccessibility: nil, likeCount: nil, subscribers: "1,25 M d\u{2019}abonn\u{E9}s"),
    ]

    @Test(arguments: localizedCounts)
    func countsInAnyLanguageKeepTheirTextAndNeverBecomeAWrongNumber(_ example: LocalizedCounts) throws {
        let json = Self.next(views: example.views, likeTitle: example.like, likeAccessibility: example.likeAccessibility, subscribers: example.subscribers)
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.viewCountText == example.views)
        #expect(d.viewCount == example.viewCount)
        #expect(d.likeCountText == example.like)
        #expect(d.likeCount == example.likeCount)
        #expect(d.subscriberCountText == example.subscribers)
    }

    // MARK: - Missing and mutated shapes

    @Test(arguments: ["{}", "[]", "null", "\"text\"", "42", #"{"contents":{}}"#, #"{"contents":{"twoColumnWatchNextResults":{}}}"#])
    func unusableResponsesGiveNil(text: String) throws {
        let json = try JSON(data: Data(text.utf8))
        #expect(WatchMetadataParser.parse(json, videoID: "abc") == nil)
    }

    @Test func wrongTypesDoNotCrash() throws {
        let json = try JSON(data: Data(#"""
        {"contents":{"twoColumnWatchNextResults":{"results":{"results":{"contents":[
          {"videoPrimaryInfoRenderer":{"title":{"simpleText":"T"},"viewCount":[],"videoActions":"x","dateText":7,"relativeDateText":null}},
          {"videoSecondaryInfoRenderer":{"owner":[1,2],"attributedDescription":{"content":5,"commandRuns":"nope"}}},
          {"itemSectionRenderer":{"sectionIdentifier":"comment-item-section","contents":"nope"}}
        ]}}}},
         "playerOverlays":[],"engagementPanels":{"a":1}}
        """#.utf8))
        let d = try #require(WatchMetadataParser.parse(json, videoID: "abc"))
        #expect(d.title == "T"); #expect(d.channel.name == ""); #expect(d.description == .empty)
        #expect(d.viewCountText == nil); #expect(d.dateText == nil); #expect(d.likeCount == nil)
        #expect(d.chapters.isEmpty); #expect(d.commentsContinuation == nil)
    }

    @Test func renamedSecondaryRendererKeepsTheRest() throws {
        let json = try Fixture.json("next_aqz.json")
        let mutated = Self.edited(json, "contents.twoColumnWatchNextResults.results.results.contents.1") { node in
            Self.renamingKey("videoSecondaryInfoRenderer", to: "videoSecondaryInfoRendererV2", in: node)
        }
        let d = try #require(WatchMetadataParser.parse(mutated, videoID: "aqz-KE-bpKQ"))
        #expect(d.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(d.viewCountText == "23,500,582 views"); #expect(d.likeCountText == "110K")
        #expect(d.channel.name == ""); #expect(d.channel.id == ""); #expect(d.subscriberCountText == nil)
        #expect(d.description == .empty)
        #expect(d.commentsContinuation != nil)
    }

    @Test func renamedPrimaryRendererFallsBackToTheOverlayTitle() throws {
        let json = try Fixture.json("next_aqz.json")
        let mutated = Self.edited(json, "contents.twoColumnWatchNextResults.results.results.contents.0") { node in
            Self.renamingKey("videoPrimaryInfoRenderer", to: "videoPrimaryInfoRendererV2", in: node)
        }
        let d = try #require(WatchMetadataParser.parse(mutated, videoID: "aqz-KE-bpKQ"))
        #expect(d.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(d.viewCountText == nil); #expect(d.dateText == nil); #expect(d.likeCountText == nil)
        #expect(d.channel.name == "Blender"); #expect(d.channel.id == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(d.description.links.count == 2)
    }

    @Test func removedChapterMarkersGiveNoChapters() throws {
        let json = try Fixture.json("next_with_chapters.json")
        let mutated = Self.edited(json, "playerOverlays.playerOverlayRenderer.decoratedPlayerBarRenderer.decoratedPlayerBarRenderer.playerBar.multiMarkersPlayerBarRenderer.markersMap") { _ in nil }
        let d = try #require(WatchMetadataParser.parse(mutated, videoID: "z-Xl9tGqH14"))
        #expect(d.chapters.isEmpty)
        #expect(d.title == "Beginner Blender Tutorial (2026)")
    }

    @Test func commentsTokenFallsBackToTheEngagementPanel() throws {
        let json = try Fixture.json("next_aqz.json")
        // Drop the in-page comments section (contents[3]); the panel's token is a different one.
        let mutated = Self.edited(json, "contents.twoColumnWatchNextResults.results.results.contents.3") { _ in nil }
        let d = try #require(WatchMetadataParser.parse(mutated, videoID: "aqz-KE-bpKQ"))
        let token = try #require(d.commentsContinuation)
        #expect(token.hasPrefix("Eg0SC2Fxei1LRS1icEtRGAYyWCIx"))
        #expect(d.commentCountText == "5.2K")
    }

    @Test func noCommentsSectionGivesNoToken() throws {
        let json = try Fixture.json("next_aqz.json")
        var mutated = Self.edited(json, "contents.twoColumnWatchNextResults.results.results.contents.3") { _ in nil }
        mutated = Self.edited(mutated, "engagementPanels") { _ in nil }
        let d = try #require(WatchMetadataParser.parse(mutated, videoID: "aqz-KE-bpKQ"))
        #expect(d.commentsContinuation == nil); #expect(d.commentCountText == nil)
        #expect(d.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
    }

    @Test func relatedStaysEmptyEvenThoughTheResponseHasSecondaryResults() throws {
        let json = try Fixture.json("next_aqz.json")
        let d = try #require(WatchMetadataParser.parse(json, videoID: "aqz-KE-bpKQ"))
        #expect(json.first("secondaryResults") != nil)
        #expect(d.related.isEmpty); #expect(d.relatedContinuation == nil)
    }

    // MARK: - Helpers

    /// A `next` response with a title, and a secondary info renderer holding `description` and its `runs`.
    private static func next(description: String, runs: [JSON]) -> JSON {
        let secondary: JSON = .object([
            "attributedDescription": .object([
                "content": .string(description),
                "commandRuns": .array(runs),
            ]),
        ])
        return nextResponse(contents: [
            .object(["videoPrimaryInfoRenderer": .object(["title": .object(["simpleText": "T"])])]),
            .object(["videoSecondaryInfoRenderer": secondary]),
        ])
    }

    /// A `next` response with a title and the given chapter marker groups (`(key, [(title, startMillis)])`).
    private static func next(chapters groups: [(String, [(String, Int)])]) -> JSON {
        let markers: [JSON] = groups.map { key, chapters in
            let items: [JSON] = chapters.map { title, millis in
                .object(["chapterRenderer": .object([
                    "title": .object(["simpleText": .string(title)]),
                    "timeRangeStartMillis": .number(Double(millis)),
                ])])
            }
            return .object(["key": .string(key), "value": .object(["chapters": .array(items)])])
        }
        var response = nextResponse(contents: [
            .object(["videoPrimaryInfoRenderer": .object(["title": .object(["simpleText": "T"])])]),
        ])
        let bar: JSON = .object(["multiMarkersPlayerBarRenderer": .object(["markersMap": .array(markers)])])
        let decorated: JSON = .object(["decoratedPlayerBarRenderer": .object(["decoratedPlayerBarRenderer": .object(["playerBar": bar])])])
        if case .object(var root) = response {
            root["playerOverlays"] = .object(["playerOverlayRenderer": decorated])
            response = .object(root)
        }
        return response
    }

    /// A `next` response whose like button has the given title and accessibility text.
    private static func next(likeTitle: String, likeAccessibility: String?) -> JSON {
        var button: [String: JSON] = ["title": .string(likeTitle)]
        if let likeAccessibility { button["accessibilityText"] = .string(likeAccessibility) }
        let toggle: JSON = .object(["toggleButtonViewModel": .object(["toggleButtonViewModel": .object([
            "defaultButtonViewModel": .object(["buttonViewModel": .object(button)]),
        ])])])
        let like: JSON = .object(["likeButtonViewModel": .object(["likeButtonViewModel": toggle])])
        let primary: JSON = .object([
            "title": .object(["simpleText": "T"]),
            "videoActions": .object(["menuRenderer": .object(["topLevelButtons": .array([
                .object(["segmentedLikeDislikeButtonViewModel": like]),
            ])])]),
        ])
        return nextResponse(contents: [.object(["videoPrimaryInfoRenderer": primary])])
    }

    /// A `next` response with a title, a view count, a like button and a channel with a subscriber count.
    private static func next(views: String, likeTitle: String, likeAccessibility: String?, subscribers: String) -> JSON {
        var button: [String: JSON] = ["title": .string(likeTitle)]
        if let likeAccessibility { button["accessibilityText"] = .string(likeAccessibility) }
        let toggle: JSON = .object(["toggleButtonViewModel": .object(["toggleButtonViewModel": .object([
            "defaultButtonViewModel": .object(["buttonViewModel": .object(button)]),
        ])])])
        let like: JSON = .object(["likeButtonViewModel": .object(["likeButtonViewModel": toggle])])
        let primary: JSON = .object([
            "title": .object(["simpleText": "T"]),
            "viewCount": .object(["videoViewCountRenderer": .object(["viewCount": .object(["simpleText": .string(views)])])]),
            "videoActions": .object(["menuRenderer": .object(["topLevelButtons": .array([
                .object(["segmentedLikeDislikeButtonViewModel": like]),
            ])])]),
        ])
        let owner: JSON = .object(["videoOwnerRenderer": .object([
            "title": .object(["runs": .array([.object(["text": "Channel"])])]),
            "subscriberCountText": .object(["simpleText": .string(subscribers)]),
        ])])
        return nextResponse(contents: [
            .object(["videoPrimaryInfoRenderer": primary]),
            .object(["videoSecondaryInfoRenderer": .object(["owner": owner])]),
        ])
    }

    /// Parses a `next` response whose secondary info holds only the given `videoOwnerRenderer`.
    private static func details(owner: JSON) throws -> VideoDetails {
        let json = nextResponse(contents: [
            .object(["videoPrimaryInfoRenderer": .object(["title": .object(["simpleText": "T"])])]),
            .object(["videoSecondaryInfoRenderer": .object(["owner": .object(["videoOwnerRenderer": owner])])]),
        ])
        return try #require(WatchMetadataParser.parse(json, videoID: "abc"))
    }

    private static func nextResponse(contents: [JSON]) -> JSON {
        .object(["contents": .object(["twoColumnWatchNextResults": .object(["results": .object(["results": .object([
            "contents": .array(contents),
        ])])])])])
    }

    private static func renamingKey(_ key: String, to newKey: String, in node: JSON) -> JSON {
        guard case .object(var object) = node, let value = object.removeValue(forKey: key) else { return node }
        object[newKey] = value
        return .object(object)
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
