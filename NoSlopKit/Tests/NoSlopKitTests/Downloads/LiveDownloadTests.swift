import AVFoundation
import Foundation
import Testing
@testable import NoSlopKit

// MARK: - Live

/// Real YouTube, real network. Opt in with `NOSLOP_LIVE=1 swift test --package-path NoSlopKit --filter Live`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NOSLOP_LIVE"] == "1"), .limitsMediaExports) struct LiveDownloadTests {
    @Test func downloadsMeAtTheZooAt144p() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        let manager = DownloadManager(
            rootDirectory: root, streams: LiveDownloadResolver(), sessionConfiguration: .ephemeral
        )

        let video = VideoSummary(id: ZooFixture.videoID, title: "Me at the zoo", channel: ChannelRef(id: "UC4QobU6STFB0P71PMvOGN5A", name: "jawed"))
        manager.enqueue(video: video, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition(timeout: .seconds(180)) { downloadIsSettled(manager, ZooFixture.itemID) })

        let item = try #require(manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        let file = try #require(manager.fileURL(for: item))
        let media = try await mediaDurationAndTracks(of: file)
        print("LIVE zoo download: \(media.seconds) s, \(item.bytesTotal ?? -1) bytes, \(file.lastPathComponent)")
        #expect(abs(media.seconds - 19) < 1.0, "duration \(media.seconds)")
        #expect(media.video == 1 && media.audio == 1)
    }
}

/// The smallest possible visionOS `player` call (the real resolver belongs to another task and is a stub here):
/// fetch a visitor id, ask for the player response, and map `adaptiveFormats` to `StreamFormat`s.
struct LiveDownloadResolver: StreamResolving {
    func streamInfo(videoID: String) async throws -> StreamInfo {
        let web = ClientProfile.web
        let vision = ClientProfile.visionOS
        let visitorBody: [String: Any] = ["context": ["client": ["clientName": web.clientName, "clientVersion": web.clientVersion, "hl": "en", "gl": "US"]]]
        let visitorJSON = try await post("visitor_id", body: visitorBody, profile: web, visitorData: nil)
        guard let visitorData = visitorJSON["responseContext"]?["visitorData"]?.string else {
            throw NoSlopError.decoding("no visitorData")
        }

        var client: [String: Any] = [
            "clientName": vision.clientName, "clientVersion": vision.clientVersion, "hl": "en", "gl": "US",
            "visitorData": visitorData,
        ]
        for (key, value) in vision.extraClientFields { client[key] = value }
        let body: [String: Any] = [
            "context": ["client": client],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
        ]
        let json = try await post("player", body: body, profile: vision, visitorData: visitorData)
        guard json["playabilityStatus"]?["status"]?.string == "OK" else {
            throw NoSlopError.unplayable(reason: json["playabilityStatus"]?["reason"]?.string ?? "not playable")
        }
        let formats = (json["streamingData"]?["adaptiveFormats"]?.array ?? []).compactMap { entry -> StreamFormat? in
            guard let itag = entry["itag"]?.int, let urlText = entry["url"]?.string, let url = URL(string: urlText),
                  let mime = entry["mimeType"]?.string else { return nil }
            return StreamFormat(
                itag: itag, url: url, mimeType: mime, bitrate: entry["bitrate"]?.int,
                width: entry["width"]?.int, height: entry["height"]?.int, fps: entry["fps"]?.int,
                qualityLabel: entry["qualityLabel"]?.string,
                contentLength: entry["contentLength"]?.string.flatMap { Int64($0) },
                approxDurationMs: entry["approxDurationMs"]?.int,
                audioSampleRate: entry["audioSampleRate"]?.int,
                isDRC: entry["isDrc"]?.bool ?? false
            )
        }
        let details = json["videoDetails"]
        return StreamInfo(
            videoID: videoID, title: details?["title"]?.string ?? "", author: details?["author"]?.string ?? "",
            channelID: details?["channelId"]?.string ?? "", lengthSeconds: details?["lengthSeconds"]?.int ?? 0,
            formats: formats, expiresAt: Date().addingTimeInterval(Double(json["streamingData"]?["expiresInSeconds"]?.int ?? 21_540))
        )
    }

    private func post(_ endpoint: String, body: [String: Any], profile: ClientProfile, visitorData: String?) async throws -> JSON {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(profile.clientNameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NoSlopError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSON(data: data)
    }
}
