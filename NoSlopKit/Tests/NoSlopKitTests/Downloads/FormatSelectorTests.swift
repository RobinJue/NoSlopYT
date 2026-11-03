import Foundation
import Testing
@testable import NoSlopKit

/// Hand-built formats that mirror `player_visionos_bigbuckbunny.json` (itags, codecs, sizes, durations).
enum BunnyDownloadFormats {
    static let avc1: [StreamFormat] = [
        video(299, "avc1.64002A", 1920, 1080, 60, "1080p60", 257_619_653, 6_933_529),
        video(298, "avc1.4D4020", 1280, 720, 60, "720p60", 150_524_867, 4_206_005),
        video(135, "avc1.4D401F", 854, 480, 30, "480p", 28_207_144, 1_098_569),
        video(134, "avc1.4D401E", 640, 360, 30, "360p", 18_294_110, 643_723),
        video(133, "avc1.4D4015", 426, 240, 30, "240p", 9_323_483, 245_550),
        video(160, "avc1.4D400C", 256, 144, 30, "144p", 4_323_893, 111_153),
    ]

    static let vp9: [StreamFormat] = [
        webm(303, "vp9", 1920, 1080, 60, "1080p60", 168_736_189),
        webm(302, "vp9", 1280, 720, 60, "720p60", 112_676_322),
        webm(244, "vp9", 854, 480, 30, "480p", 33_138_062),
        webm(243, "vp9", 640, 360, 30, "360p", 24_109_536),
        webm(242, "vp9", 426, 240, 30, "240p", 10_198_281),
        webm(278, "vp9", 256, 144, 30, "144p", 5_289_812),
    ]

    static let av01: [StreamFormat] = [
        video(399, "av01.0.09M.08", 1920, 1080, 60, "1080p60", 124_386_876, 4_492_945),
        video(398, "av01.0.08M.08", 1280, 720, 60, "720p60", 71_283_827, 2_603_249),
        video(397, "av01.0.04M.08", 854, 480, 30, "480p", 25_998_574, 787_121),
        video(396, "av01.0.01M.08", 640, 360, 30, "360p", 15_298_808, 434_276),
        video(395, "av01.0.00M.08", 426, 240, 30, "240p", 7_576_787, 193_616),
        video(394, "av01.0.00M.08", 256, 144, 30, "144p", 4_639_733, 104_269),
    ]

    /// itag 140 AAC-LC 44.1 kHz twice (plain and DRC), itag 139 HE-AAC, Opus (itags 249, 250, 251).
    static let audio: [StreamFormat] = [
        aac(139, "mp4a.40.5", 3_871_021, 634_694, 50_452, 22_050, drc: false),
        aac(139, "mp4a.40.5", 3_871_021, 634_694, 50_429, 22_050, drc: true),
        aac(140, "mp4a.40.2", 10_271_496, 634_624, 130_992, 44_100, drc: false),
        aac(140, "mp4a.40.2", 10_271_496, 634_624, 131_003, 44_100, drc: true),
        opus(249, 3_931_453, 57_946, drc: false),
        opus(250, 5_186_043, 75_580, drc: false),
        opus(251, 10_202_210, 143_452, drc: false),
        opus(251, 10_258_925, 143_908, drc: true),
    ]

    /// Everything, in the order the player response lists it: video by descending height, then audio.
    static let all: [StreamFormat] = avc1 + vp9 + av01 + audio

    /// The plain (non-DRC) AAC-LC copy of itag 140.
    static let aac140 = audio[2]

    static func format(_ itag: Int, drc: Bool = false) -> StreamFormat {
        guard let format = all.first(where: { $0.itag == itag && $0.isDRC == drc }) else {
            fatalError("no itag \(itag) (drc \(drc)) in the Big Buck Bunny formats")
        }
        return format
    }

    private static func url(_ itag: Int) -> URL {
        URL(string: "https://rr1.googlevideo.invalid/videoplayback?itag=\(itag)")!
    }

    private static func video(
        _ itag: Int, _ codec: String, _ width: Int, _ height: Int, _ fps: Int, _ label: String,
        _ length: Int64, _ bitrate: Int
    ) -> StreamFormat {
        StreamFormat(
            itag: itag, url: url(itag), mimeType: "video/mp4; codecs=\"\(codec)\"", bitrate: bitrate,
            width: width, height: height, fps: fps, qualityLabel: label,
            contentLength: length, approxDurationMs: 634_566
        )
    }

    private static func webm(
        _ itag: Int, _ codec: String, _ width: Int, _ height: Int, _ fps: Int, _ label: String, _ length: Int64
    ) -> StreamFormat {
        StreamFormat(
            itag: itag, url: url(itag), mimeType: "video/webm; codecs=\"\(codec)\"",
            width: width, height: height, fps: fps, qualityLabel: label,
            contentLength: length, approxDurationMs: 634_566
        )
    }

    private static func aac(
        _ itag: Int, _ codec: String, _ length: Int64, _ durationMs: Int, _ bitrate: Int, _ sampleRate: Int, drc: Bool
    ) -> StreamFormat {
        StreamFormat(
            itag: itag, url: url(itag), mimeType: "audio/mp4; codecs=\"\(codec)\"", bitrate: bitrate,
            contentLength: length, approxDurationMs: durationMs, audioSampleRate: sampleRate, isDRC: drc
        )
    }

    private static func opus(_ itag: Int, _ length: Int64, _ bitrate: Int, drc: Bool) -> StreamFormat {
        StreamFormat(
            itag: itag, url: url(itag), mimeType: "audio/webm; codecs=\"opus\"", bitrate: bitrate,
            contentLength: length, approxDurationMs: 634_601, audioSampleRate: 48_000, isDRC: drc
        )
    }
}

@Suite struct FormatSelectorTests {
    @Test func picks720() throws {
        let selected = try #require(FormatSelector.select(from: BunnyDownloadFormats.all, quality: .video(maxHeight: 720)))
        #expect(selected.video?.itag == 298)
        #expect(selected.audio.itag == 140)
        #expect(selected.audio.isDRC == false)
    }

    @Test func picks1080() throws {
        let selected = try #require(FormatSelector.select(from: BunnyDownloadFormats.all, quality: .video(maxHeight: 1080)))
        #expect(selected.video?.itag == 299)
        #expect(selected.audio.itag == 140 && !selected.audio.isDRC)
    }

    @Test func picks360() throws {
        let selected = try #require(FormatSelector.select(from: BunnyDownloadFormats.all, quality: .video(maxHeight: 360)))
        #expect(selected.video?.itag == 134)
        #expect(selected.audio.itag == 140 && !selected.audio.isDRC)
    }

    @Test func audioOnly() throws {
        let selected = try #require(FormatSelector.select(from: BunnyDownloadFormats.all, quality: .audioOnly))
        #expect(selected.video == nil)
        #expect(selected.audio.itag == 140)
        #expect(selected.audio.isDRC == false)
    }

    @Test func fallsBackToDRCAudioWhenOnlyOption() throws {
        let formats = BunnyDownloadFormats.avc1 + [BunnyDownloadFormats.format(140, drc: true)]
        let selected = try #require(FormatSelector.select(from: formats, quality: .video(maxHeight: 720)))
        #expect(selected.video?.itag == 298)
        #expect(selected.audio.itag == 140)
        #expect(selected.audio.isDRC == true)
        let audioOnly = try #require(FormatSelector.select(from: formats, quality: .audioOnly))
        #expect(audioOnly.audio.isDRC == true)
    }

    @Test func fallsBackToLowestAvc1WhenNoneUnderCap() throws {
        let only1080 = [BunnyDownloadFormats.format(299), BunnyDownloadFormats.aac140]
        let selected = try #require(FormatSelector.select(from: only1080, quality: .video(maxHeight: 360)))
        #expect(selected.video?.itag == 299)

        // With several above the cap, the smallest of them wins.
        let above = [BunnyDownloadFormats.format(299), BunnyDownloadFormats.format(298), BunnyDownloadFormats.aac140]
        let lowest = try #require(FormatSelector.select(from: above, quality: .video(maxHeight: 360)))
        #expect(lowest.video?.itag == 298)
    }

    @Test func ignoresIncompatibleCodecs() {
        let onlyVP9AndOpus = BunnyDownloadFormats.vp9 + BunnyDownloadFormats.audio.filter { $0.mimeType.contains("opus") }
        #expect(FormatSelector.select(from: onlyVP9AndOpus, quality: .video(maxHeight: 720)) == nil)
        #expect(FormatSelector.select(from: onlyVP9AndOpus, quality: .audioOnly) == nil)
        // AV1 in MP4 is not playable by AVFoundation either.
        let av1WithAAC = BunnyDownloadFormats.av01 + [BunnyDownloadFormats.aac140]
        #expect(FormatSelector.select(from: av1WithAAC, quality: .video(maxHeight: 720)) == nil)
        #expect(FormatSelector.select(from: av1WithAAC, quality: .audioOnly)?.audio.itag == 140)
    }

    @Test func noFormatsAtAll() {
        #expect(FormatSelector.select(from: [], quality: .video(maxHeight: 720)) == nil)
        #expect(FormatSelector.select(from: [], quality: .audioOnly) == nil)
    }

    @Test func videoWithoutAudioCannotBeDownloaded() {
        #expect(FormatSelector.select(from: BunnyDownloadFormats.avc1, quality: .video(maxHeight: 720)) == nil)
    }

    @Test func audioOnlyNeedsNoVideo() throws {
        let selected = try #require(FormatSelector.select(from: [BunnyDownloadFormats.aac140], quality: .audioOnly))
        #expect(selected.video == nil && selected.audio.itag == 140)
    }

    @Test func aCapBetweenRungsPicksTheHighestBelow() throws {
        let selected = try #require(FormatSelector.select(from: BunnyDownloadFormats.all, quality: .video(maxHeight: 600)))
        #expect(selected.video?.itag == 135)
    }

    @Test func prefersTheHigherFrameRateAtTheSameHeight() throws {
        var thirty = BunnyDownloadFormats.format(298)
        thirty.itag = 136
        thirty.fps = 30
        thirty.bitrate = 2_000_000
        let formats = [thirty, BunnyDownloadFormats.format(298), BunnyDownloadFormats.aac140]
        let selected = try #require(FormatSelector.select(from: formats, quality: .video(maxHeight: 720)))
        #expect(selected.video?.itag == 298)
    }

    @Test func prefersTheHigherBitrateWhenEverythingElseIsEqual() throws {
        var low = BunnyDownloadFormats.format(135)
        low.itag = 900
        low.bitrate = 500_000
        let formats = [low, BunnyDownloadFormats.format(135), BunnyDownloadFormats.aac140]
        let selected = try #require(FormatSelector.select(from: formats, quality: .video(maxHeight: 480)))
        #expect(selected.video?.itag == 135)
    }

    @Test func progressiveFormatsAreNeverTheVideoSource() throws {
        // itag 18 style: H.264 + AAC in one file. The muxer needs a video-only track, so it must be skipped.
        let progressive = StreamFormat(
            itag: 18, url: URL(string: "https://example.invalid/18")!,
            mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
            width: 640, height: 360, fps: 30, qualityLabel: "360p", contentLength: 1_000, isProgressive: true
        )
        let formats = [progressive, BunnyDownloadFormats.format(133), BunnyDownloadFormats.aac140]
        let selected = try #require(FormatSelector.select(from: formats, quality: .video(maxHeight: 360)))
        #expect(selected.video?.itag == 133)
        #expect(FormatSelector.select(from: [progressive], quality: .video(maxHeight: 360)) == nil)
    }

    @Test func portraitVideoIsClassifiedByItsQualityLabel() throws {
        // A 9:16 video: the "1080p" rendition is 1080x1920, so `height` alone would call it 1920p.
        let portrait1080 = StreamFormat(
            itag: 299, url: URL(string: "https://example.invalid/299")!, mimeType: "video/mp4; codecs=\"avc1.640028\"",
            width: 1080, height: 1920, fps: 30, qualityLabel: "1080p", contentLength: 9_000
        )
        let portrait360 = StreamFormat(
            itag: 134, url: URL(string: "https://example.invalid/134")!, mimeType: "video/mp4; codecs=\"avc1.4D401E\"",
            width: 360, height: 640, fps: 30, qualityLabel: "360p", contentLength: 3_000
        )
        let formats = [portrait1080, portrait360, BunnyDownloadFormats.aac140]
        #expect(FormatSelector.select(from: formats, quality: .video(maxHeight: 1080))?.video?.itag == 299)
        #expect(FormatSelector.select(from: formats, quality: .video(maxHeight: 720))?.video?.itag == 134)
    }

    @Test func classifiesByTheShortSideWhenThereIsNoLabel() throws {
        let noLabel = StreamFormat(
            itag: 298, url: URL(string: "https://example.invalid/298")!, mimeType: "video/mp4; codecs=\"avc1.4D4020\"",
            width: 1280, height: 720, contentLength: 1_000
        )
        let heightOnly = StreamFormat(
            itag: 135, url: URL(string: "https://example.invalid/135")!, mimeType: "video/mp4; codecs=\"avc1.4D401F\"",
            height: 480, contentLength: 500
        )
        let formats = [noLabel, heightOnly, BunnyDownloadFormats.aac140]
        #expect(FormatSelector.select(from: formats, quality: .video(maxHeight: 720))?.video?.itag == 298)
        #expect(FormatSelector.select(from: formats, quality: .video(maxHeight: 480))?.video?.itag == 135)
    }

    @Test func aVideoThatDoesNotSayHowTallItIsIsTheLastResort() throws {
        let unknown = StreamFormat(
            itag: 1, url: URL(string: "https://example.invalid/1")!, mimeType: "video/mp4; codecs=\"avc1.4D401F\"", contentLength: 5
        )
        // Alone, it is used for any cap...
        #expect(FormatSelector.select(from: [unknown, BunnyDownloadFormats.aac140], quality: .video(maxHeight: 720))?.video?.itag == 1)
        #expect(FormatSelector.select(from: [unknown, BunnyDownloadFormats.aac140], quality: .video(maxHeight: 144))?.video?.itag == 1)
        // ...but a rendition with a known height wins whenever it fits under the cap.
        let formats = [unknown, BunnyDownloadFormats.format(298), BunnyDownloadFormats.aac140]
        #expect(try #require(FormatSelector.select(from: formats, quality: .video(maxHeight: 720))).video?.itag == 298)
        #expect(try #require(FormatSelector.select(from: formats, quality: .video(maxHeight: 360))).video?.itag == 1)
        // It cannot be named in the quality sheet.
        #expect(FormatSelector.options(from: [unknown, BunnyDownloadFormats.aac140]).map(\.label) == ["Audio only"])
    }

    @Test func audioChoiceDoesNotNeedBitrates() throws {
        // Hand-built lists often leave the optional numbers out; 140 must still beat 139.
        func bare(_ itag: Int, _ codec: String, drc: Bool = false) -> StreamFormat {
            StreamFormat(itag: itag, url: URL(string: "https://example.invalid/\(itag)")!, mimeType: "audio/mp4; codecs=\"\(codec)\"", isDRC: drc)
        }
        let formats = [bare(139, "mp4a.40.5"), bare(140, "mp4a.40.2", drc: true), bare(140, "mp4a.40.2"), bare(251, "opus")]
        let selected = try #require(FormatSelector.select(from: formats, quality: .audioOnly))
        #expect(selected.audio.itag == 140 && !selected.audio.isDRC)
    }

    @Test func selectedFormatsAreValueEqual() throws {
        let a = try #require(FormatSelector.select(from: BunnyDownloadFormats.all, quality: .video(maxHeight: 720)))
        let b = try #require(FormatSelector.select(from: Array(BunnyDownloadFormats.all.reversed()), quality: .video(maxHeight: 720)))
        #expect(a == b)
    }

    // MARK: Options for the quality sheet

    @Test func optionsCoverTheLadderAndAudio() {
        let options = FormatSelector.options(from: BunnyDownloadFormats.all)
        #expect(options.map(\.label) == ["1080p", "720p", "480p", "360p", "Audio only"])
        #expect(options.map(\.quality) == [.video(maxHeight: 1080), .video(maxHeight: 720), .video(maxHeight: 480), .video(maxHeight: 360), .audioOnly])
        let audio: Int64 = 10_271_496
        #expect(options.map(\.estimatedBytes) == [257_619_653 + audio, 150_524_867 + audio, 28_207_144 + audio, 18_294_110 + audio, audio])
        #expect(options.map(\.id) == ["1080", "720", "480", "360", "audio"])
    }

    @Test func optionsSkipRungsThatWouldRepeatAnotherRung() {
        // Nothing above 720p: no 1080p entry that secretly downloads 720p.
        let upTo720 = BunnyDownloadFormats.all.filter { $0.itag != 299 && $0.itag != 303 && $0.itag != 399 }
        #expect(FormatSelector.options(from: upTo720).map(\.label) == ["720p", "480p", "360p", "Audio only"])

        // No 480p: the 480p rung would give 360p again.
        let no480 = BunnyDownloadFormats.all.filter { $0.itag != 135 }
        #expect(FormatSelector.options(from: no480).map(\.label) == ["1080p", "720p", "360p", "Audio only"])
    }

    @Test func optionsForAnOldLowResolutionVideoAreLabelledHonestly() {
        let video = StreamFormat(
            itag: 160, url: URL(string: "https://example.invalid/160")!, mimeType: "video/mp4; codecs=\"avc1.4D400C\"",
            width: 192, height: 144, fps: 15, qualityLabel: "144p", contentLength: 195_278
        )
        let options = FormatSelector.options(from: [video, BunnyDownloadFormats.aac140])
        #expect(options.map(\.label) == ["144p", "Audio only"])
        #expect(options.first?.quality == .video(maxHeight: 144))
    }

    @Test func optionsWithoutSizesStillList() {
        let bare = BunnyDownloadFormats.all.map { format -> StreamFormat in
            var copy = format
            copy.contentLength = nil
            return copy
        }
        let options = FormatSelector.options(from: bare)
        #expect(options.map(\.label) == ["1080p", "720p", "480p", "360p", "Audio only"])
        #expect(options.allSatisfy { $0.estimatedBytes == nil })
    }

    @Test func optionsAreEmptyWithoutDownloadableFormats() {
        #expect(FormatSelector.options(from: []).isEmpty)
        #expect(FormatSelector.options(from: BunnyDownloadFormats.vp9).isEmpty)
        // Video without any audio to go with it cannot be offered; neither can audio that is missing.
        #expect(FormatSelector.options(from: BunnyDownloadFormats.avc1).isEmpty)
        #expect(FormatSelector.options(from: [BunnyDownloadFormats.aac140]).map(\.label) == ["Audio only"])
    }

    @Test func sizesThatCannotBeAddedAreNoEstimateAndNeverACrash() {
        // video + audio would overflow Int64: a trap here would take the whole app down when the sheet opens.
        var absurd = BunnyDownloadFormats.all
        for index in absurd.indices { absurd[index].contentLength = Int64.max }
        let options = FormatSelector.options(from: absurd)
        #expect(options.map(\.label) == ["1080p", "720p", "480p", "360p", "Audio only"])
        #expect(options.dropLast().allSatisfy { $0.estimatedBytes == nil }, "a sum that does not fit is not an estimate")
        #expect(options.last?.estimatedBytes == Int64.max, "a size that fits is still reported")
    }

    @Test func zeroAndNegativeSizesAreUnknownSizes() {
        // The download itself treats them as "not stated" (it falls back to the URL's clen), so the sheet must not
        // present them as a real size either.
        var odd = BunnyDownloadFormats.all
        for index in odd.indices { odd[index].contentLength = index.isMultiple(of: 2) ? 0 : -5 }
        let options = FormatSelector.options(from: odd)
        #expect(options.map(\.label) == ["1080p", "720p", "480p", "360p", "Audio only"])
        #expect(options.allSatisfy { $0.estimatedBytes == nil })
    }
}
