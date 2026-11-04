import AVFoundation
import Foundation
import Testing
@testable import NoSlopKit

// Merges that finish at the same time must not all run an AVAssetExportSession at the same time: each export blocks
// the cooperative-pool thread it was started on, and with enough of them CoreMedia stops answering (see `ExportGate`).
// This suite deliberately does NOT use `.limitsMediaExports`: it exercises the gate that production code runs under.
@Suite(.timeLimit(.minutes(2))) struct MediaMuxerConcurrencyTests {
    private static let trueDuration = 18.933

    private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    @Test func manyMergesAtOnceAllFinish() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let video = try Fixture.url("zoo_video_144p.mp4")
        let audio = try Fixture.url("zoo_audio.m4a")

        // Four times as many merges as the machine has cores, all at once, each to a file of its own.
        let count = 4 * ProcessInfo.processInfo.activeProcessorCount
        let durations = try await withThrowingTaskGroup(of: Double.self) { group in
            for index in 0..<count {
                let output = directory.url.appendingPathComponent("merge-\(index).mp4")
                group.addTask {
                    try await MediaMuxer.mux(videoFile: video, audioFile: audio, durationSeconds: Self.trueDuration, output: output)
                    return try await AVURLAsset(url: output).load(.duration).seconds
                }
            }
            var all: [Double] = []
            for try await seconds in group { all.append(seconds) }
            return all
        }

        #expect(durations.count == count)
        #expect(durations.allSatisfy { abs($0 - 18.93) < 0.05 }, "durations \(durations)")
    }

    @Test func anExportWaitsForAPermitInsteadOfStartingAtOnce() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("merged.mp4")
        let video = try Fixture.url("zoo_video_144p.mp4")
        let audio = try Fixture.url("zoo_audio.m4a")

        let gate = ExportGate(permits: 1)
        try await gate.acquire()   // the only permit is taken
        let merge = Task {
            try await MediaMuxer.mux(videoFile: video, audioFile: audio, durationSeconds: Self.trueDuration, output: output, gate: gate)
        }
        #expect(await eventually(timeout: .seconds(5)) { await gate.waitingCount == 1 }, "the export queued for a permit")
        #expect(!FileManager.default.fileExists(atPath: output.path), "nothing is exported while the gate is closed")

        await gate.release()
        try await merge.value
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 18.93) < 0.05, "duration \(duration)")
        #expect(await gate.availablePermits == 1, "the permit is back")
        #expect(await gate.waitingCount == 0)
    }

    @Test func aMergeThatIsCancelledWhileItWaitsExportsNothingAndKeepsNoPermit() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("merged.mp4")
        let video = try Fixture.url("zoo_video_144p.mp4")
        let audio = try Fixture.url("zoo_audio.m4a")

        let gate = ExportGate(permits: 1)
        try await gate.acquire()
        let merge = Task {
            try await MediaMuxer.mux(videoFile: video, audioFile: audio, durationSeconds: Self.trueDuration, output: output, gate: gate)
        }
        #expect(await eventually(timeout: .seconds(5)) { await gate.waitingCount == 1 })

        merge.cancel()
        await #expect(throws: CancellationError.self) { try await merge.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(await gate.waitingCount == 0, "it left the line")
        #expect(await gate.availablePermits == 0, "and the permit is still the test's")

        await gate.release()
        #expect(await gate.availablePermits == 1)
    }

    @Test func aMergeThatFailsGivesItsPermitBack() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let garbage = directory.url.appendingPathComponent("audio.m4a")
        try Data(repeating: 0x42, count: 4_096).write(to: garbage)

        let gate = ExportGate(permits: 1)
        await #expect(throws: (any Error).self) {
            try await MediaMuxer.mux(
                videoFile: nil, audioFile: garbage, durationSeconds: 10,
                output: directory.url.appendingPathComponent("out.m4a"), gate: gate
            )
        }
        #expect(await gate.availablePermits == 1)
    }
}
