import Foundation

/// Turns a `player` response into a `StreamInfo`. The only parser that throws: playability errors
/// (`.botCheck`, `.unplayable`, `.notPlayableYet`) are surfaced to the user.
///
/// - `playabilityStatus`: `OK` continues; `LOGIN_REQUIRED` with a reason that mentions a bot is `.botCheck`;
///   `LIVE_STREAM_OFFLINE` (a live event or premiere that has not begun) is `.notPlayableYet`, which will play later and is
///   worth asking for again; any other status is `.unplayable`, YouTube's verdict about the video. Both carry YouTube's
///   reason (or the status itself when there is none).
/// - Formats come from `streamingData.formats` (progressive) and `adaptiveFormats`. Entries without a plain `url`
///   (ciphered or SABR-only) are skipped. A response with neither an HLS manifest nor a usable format is
///   `.notPlayableYet` too: that is a statement about the answer, not a verdict about the video.
public enum PlayerResponseParser {
    /// `streamingData.expiresInSeconds` is about six hours; this is used when the response does not say.
    static let defaultLifetime: TimeInterval = 21_540

    static let noStreamsReason = "No playable streams were returned for this video."

    public static func parse(_ json: JSON, now: Date) throws -> StreamInfo {
        try checkPlayability(json)

        guard let details = json["videoDetails"], let videoID = details["videoId"]?.string, !videoID.isEmpty else {
            throw NoSlopError.decoding("The player response has no video details.")
        }

        let streaming = json["streamingData"]
        let hlsURL = streaming?["hlsManifestUrl"]?.string.flatMap(url(from:))
        let formats = formats(in: streaming?["formats"], isProgressive: true)
            + formats(in: streaming?["adaptiveFormats"], isProgressive: false)
        guard hlsURL != nil || !formats.isEmpty else {
            throw NoSlopError.notPlayableYet(reason: noStreamsReason)
        }

        let lifetime = streaming?["expiresInSeconds"]?.double.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? defaultLifetime

        return StreamInfo(
            videoID: videoID,
            title: details["title"]?.string ?? "",
            author: details["author"]?.string ?? "",
            channelID: details["channelId"]?.string ?? "",
            lengthSeconds: details["lengthSeconds"]?.int ?? 0,
            viewCount: details["viewCount"]?.int,
            shortDescription: details["shortDescription"]?.string,
            thumbnails: InnerTubeText.thumbnails(details["thumbnail"]),
            isLive: details["isLive"]?.bool == true,
            hlsURL: hlsURL,
            formats: formats,
            captions: captionTracks(in: json),
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    // MARK: Playability

    private static func checkPlayability(_ json: JSON) throws {
        guard let playability = json["playabilityStatus"], let status = playability["status"]?.string else {
            throw NoSlopError.decoding("The player response has no playability status.")
        }
        if status == "OK" { return }

        let reason = reason(in: playability)
        if status == "LOGIN_REQUIRED", let reason, isBotCheck(reason) {
            throw NoSlopError.botCheck
        }
        // A live event or premiere that has not begun ("This live event will begin in 2 hours.") is no verdict about the
        // video: it will play, and the player's Retry is worth pressing.
        if status == "LIVE_STREAM_OFFLINE" {
            throw NoSlopError.notPlayableYet(reason: reason ?? status)
        }
        throw NoSlopError.unplayable(reason: reason ?? status)
    }

    /// The reason text is localised by the request's `hl`, so "mentions a bot" has to work beyond English: "bot"
    /// covers most Latin-script languages (also inside "robot"), the rest are the usual words for bot or robot.
    private static let botWords = [
        "bot", "robô", "бот", "ρομπότ", "ボット", "ロボット", "机器人", "機器人", "로봇", "봇",
        "روبوت", "רובוט", "रोबोट", "बॉट", "บอท", "บอต", "หุ่นยนต์",
    ]

    private static func isBotCheck(_ reason: String) -> Bool {
        botWords.contains { reason.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// YouTube's explanation: `reason`, else the error screen's reason or sub-reason, else the first message.
    private static func reason(in playability: JSON) -> String? {
        let screen = playability["errorScreen"]?["playerErrorMessageRenderer"]
        let candidates = [
            InnerTubeText.text(playability["reason"]),
            InnerTubeText.text(screen?["reason"]),
            InnerTubeText.text(screen?["subreason"]),
            InnerTubeText.text(playability["messages"]?[0]),
        ]
        return candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    // MARK: Formats

    private static func formats(in node: JSON?, isProgressive: Bool) -> [StreamFormat] {
        (node?.array ?? []).compactMap { format(from: $0, isProgressive: isProgressive) }
    }

    private static func format(from json: JSON, isProgressive: Bool) -> StreamFormat? {
        guard let itag = json["itag"]?.int,
              let mimeType = json["mimeType"]?.string, !mimeType.isEmpty,
              let urlString = json["url"]?.string, let url = url(from: urlString) else { return nil }
        return StreamFormat(
            itag: itag,
            url: url,
            mimeType: mimeType,
            bitrate: json["bitrate"]?.int,
            width: json["width"]?.int,
            height: json["height"]?.int,
            fps: json["fps"]?.int,
            qualityLabel: json["qualityLabel"]?.string,
            contentLength: json["contentLength"]?.int.map { Int64($0) },
            approxDurationMs: json["approxDurationMs"]?.int,
            audioSampleRate: json["audioSampleRate"]?.int,
            // The flag is authoritative; the URL carries "xtags=drc%3D1" on the same variants as a second hint.
            isDRC: json["isDrc"]?.bool == true || urlString.contains("xtags=drc"),
            isProgressive: isProgressive
        )
    }

    private static func url(from string: String) -> URL? {
        string.isEmpty ? nil : URL(string: string)
    }

    // MARK: Captions

    private static func captionTracks(in json: JSON) -> [CaptionTrack] {
        let tracks = json["captions"]?["playerCaptionsTracklistRenderer"]?["captionTracks"]?.array ?? []
        var seen = Set<String>()
        var result: [CaptionTrack] = []
        for track in tracks {
            guard let language = track["languageCode"]?.string, !language.isEmpty,
                  let baseURL = track["baseUrl"]?.string.flatMap(url(from:)) else { continue }
            let candidate = CaptionTrack(
                languageCode: language,
                name: InnerTubeText.text(track["name"]) ?? language,
                baseURL: baseURL,
                isAutoGenerated: track["kind"]?.string == "asr"
            )
            // `id` is the track's identity in lists; two tracks of one language and kind would collide.
            if seen.insert(candidate.id).inserted {
                result.append(candidate)
            }
        }
        return result
    }
}
