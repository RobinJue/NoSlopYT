import AVFoundation
import Foundation
import Testing
@testable import NoSlopKit

@Suite struct MediaMuxerTests {
    /// The true duration of `zoo_video_144p.mp4` (the format's `approxDurationMs` is 18933).
    static let trueDuration = 18.933

    @Test func zooClampedDuration() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("zoo.mp4")

        // AVFoundation alone reports about twice the real length for these fragmented MP4 files (37.9 s / 38.2 s).
        try await MediaMuxer.mux(
            videoFile: try Fixture.url("zoo_video_144p.mp4"),
            audioFile: try Fixture.url("zoo_audio.m4a"),
            durationSeconds: Self.trueDuration,
            output: output
        )

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 18.93) < 0.05, "duration \(duration)")
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 100_000, "the muxed file carries both streams")
    }

    @Test func eachTrackIsClampedNotJustTheContainer() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("zoo.mp4")
        try await MediaMuxer.mux(
            videoFile: try Fixture.url("zoo_video_144p.mp4"),
            audioFile: try Fixture.url("zoo_audio.m4a"),
            durationSeconds: Self.trueDuration,
            output: output
        )
        let asset = AVURLAsset(url: output)
        // The audio track ends on a whole AAC packet (23 ms each) a little before the cut, so it gets more slack.
        for (type, tolerance) in [(AVMediaType.video, 0.05), (.audio, 0.15)] {
            let track = try #require(try await asset.loadTracks(withMediaType: type).first)
            let range = try await track.load(.timeRange)
            #expect(abs(range.duration.seconds - 18.93) < tolerance, "\(type.rawValue) track lasts \(range.duration.seconds)")
        }
    }

    @Test func audioOnlyClampedDuration() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("zoo.m4a")

        // The audio alone would be reported as 38.17 s.
        try await MediaMuxer.mux(
            videoFile: nil,
            audioFile: try Fixture.url("zoo_audio.m4a"),
            durationSeconds: Self.trueDuration,
            output: output
        )

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 18.93) < 0.05, "duration \(duration)")
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @Test func anyShorterDurationIsHonoured() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("short.mp4")
        try await MediaMuxer.mux(
            videoFile: try Fixture.url("zoo_video_144p.mp4"),
            audioFile: try Fixture.url("zoo_audio.m4a"),
            durationSeconds: 5,
            output: output
        )
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 5) < 0.1, "duration \(duration)")
    }

    @Test func existingOutputIsReplaced() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("zoo.mp4")
        try Data("stale leftovers of an earlier run".utf8).write(to: output)

        try await MediaMuxer.mux(
            videoFile: try Fixture.url("zoo_video_144p.mp4"),
            audioFile: try Fixture.url("zoo_audio.m4a"),
            durationSeconds: Self.trueDuration,
            output: output
        )
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 18.93) < 0.05)
    }

    @Test func missingAudioFileThrowsAndLeavesNoOutput() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("nothing.mp4")
        await #expect(throws: (any Error).self) {
            try await MediaMuxer.mux(
                videoFile: try Fixture.url("zoo_video_144p.mp4"),
                audioFile: directory.url.appendingPathComponent("does-not-exist.m4a"),
                durationSeconds: Self.trueDuration,
                output: output
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func aFileWithoutTheRequestedTrackThrows() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("wrong.mp4")
        // The audio file passed as the video source has no video track.
        await #expect(throws: (any Error).self) {
            try await MediaMuxer.mux(
                videoFile: try Fixture.url("zoo_audio.m4a"),
                audioFile: try Fixture.url("zoo_audio.m4a"),
                durationSeconds: Self.trueDuration,
                output: output
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func garbageInputThrowsInsteadOfCrashing() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let garbage = directory.url.appendingPathComponent("audio.m4a")
        try Data(repeating: 0x42, count: 4_096).write(to: garbage)
        await #expect(throws: (any Error).self) {
            try await MediaMuxer.mux(
                videoFile: nil,
                audioFile: garbage,
                durationSeconds: 10,
                output: directory.url.appendingPathComponent("out.m4a")
            )
        }
    }
}
