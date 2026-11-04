import AVFoundation
import Foundation
import Testing
@testable import NoSlopKit

// A merge that fails for a reason that is not the files' fault (the system interrupted the export, most of all by
// suspending the app when its background time ran out) must not throw away the downloaded streams: the retry only has to
// merge again. A merge that showed the files to be bad still discards them (`downloadedGarbageFailsTheMergeAndLeavesNoFile`).

@MainActor
@Suite(.limitsMediaExports) struct MergeInterruptionTests {
    private func exists(_ name: String, in work: URL) -> Bool {
        FileManager.default.fileExists(atPath: work.appendingPathComponent(name).path)
    }

    /// The first merge fails with `failure`; the ones after it run for real. `merges` counts all of them.
    private func tuning(failingOnce failure: any Error, counting merges: DownloadTestCounter) -> DownloadTuning {
        var tuning = DownloadTuning.testing
        tuning.mux = { video, audio, duration, output in
            merges.increment()
            if merges.value == 1 { throw failure }
            try await MediaMuxer.mux(videoFile: video, audioFile: audio, durationSeconds: duration, output: output)
        }
        return tuning
    }

    @Test func aMergeTheSystemInterruptedKeepsTheStreamsAndTheRetryOnlyMergesAgain() async throws {
        let merges = DownloadTestCounter()
        let harness = try DownloadHarness.zoo(tuning: tuning(failingOnce: DownloadFailure.mergeInterrupted, counting: merges))
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })

        let failed = try #require(harness.manager.items.first)
        #expect(failed.state == .failed)
        #expect(failed.errorMessage == "Interrupted while combining the video and audio. Retry to finish.")
        let work = harness.workDirectory(for: ZooFixture.itemID)
        #expect(exists("video.mp4", in: work) && exists("audio.m4a", in: work), "the downloaded streams stay")
        #expect(harness.rootListing().filter { $0.hasSuffix(".mp4") }.isEmpty, "no final file")

        let requestsBefore = harness.server.requests.count
        harness.manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })

        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        #expect(merges.value == 2)
        #expect(harness.server.requests.count == requestsBefore, "nothing was fetched again: only the merge was repeated")
        let media = try await mediaDurationAndTracks(of: try #require(harness.manager.fileURL(for: item)))
        #expect(abs(media.seconds - 18.93) < 0.05)
        #expect(media.video == 1 && media.audio == 1)
        #expect(!harness.exists(work), "the work directory goes once the file is whole")
    }

    @Test func anInterruptionThatReachesTheManagerAsAPlainAVFoundationErrorIsTreatedTheSame() async throws {
        // An error from reading a track, say, which nothing wrapped on its way out of the muxer.
        let interrupted = NSError(domain: AVFoundationErrorDomain, code: -11847, userInfo: [NSLocalizedDescriptionKey: "Operation Interrupted"])
        let merges = DownloadTestCounter()
        let harness = try DownloadHarness.zoo(tuning: tuning(failingOnce: interrupted, counting: merges))
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })

        let failed = try #require(harness.manager.items.first)
        #expect(failed.state == .failed)
        #expect(failed.errorMessage == "Interrupted while combining the video and audio. Retry to finish.")
        let work = harness.workDirectory(for: ZooFixture.itemID)
        #expect(exists("video.mp4", in: work) && exists("audio.m4a", in: work))
    }

    @Test func aMergeThatShowedTheFilesToBeBadStillDiscardsThem() async throws {
        let merges = DownloadTestCounter()
        let harness = try DownloadHarness.zoo(tuning: tuning(failingOnce: DownloadFailure.mergeFailed("The downloaded video is empty."), counting: merges))
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })

        let failed = try #require(harness.manager.items.first)
        #expect(failed.state == .failed)
        #expect(failed.errorMessage == "Couldn't combine the video and audio.")
        #expect(!harness.exists(harness.workDirectory(for: ZooFixture.itemID)), "bad streams are not kept: the retry downloads them again")
    }

    // MARK: Which failures keep the streams

    @Test func theStreamsAreKeptUnlessTheMergeShowedThemToBeBad() {
        let noSpace = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let interrupted = NSError(domain: AVFoundationErrorDomain, code: -11819)
        let keeping: [any Error] = [
            DownloadFailure.mergeInterrupted, DownloadFailure.outOfSpace, DownloadFailure.fileSystem("could not write"),
            DownloadFailure.missingParts, noSpace, interrupted,
        ]
        for error in keeping {
            #expect(DownloadManager.keepsStreams(afterMergeFailure: error, backgroundTimeRanOut: false), "\(error)")
        }

        // -11829 is "file failed to parse": the file is what is wrong.
        let bad: [any Error] = [
            DownloadFailure.mergeFailed("The downloaded video can't be read."),
            NSError(domain: AVFoundationErrorDomain, code: -11829),
        ]
        for error in bad {
            #expect(!DownloadManager.keepsStreams(afterMergeFailure: error, backgroundTimeRanOut: false), "\(error)")
        }

        // Once iOS has said the extra background time is over, the app is about to be suspended in the middle of the
        // merge: whatever fails after that does not say anything about the files.
        for error in keeping + bad {
            #expect(DownloadManager.keepsStreams(afterMergeFailure: error, backgroundTimeRanOut: true), "\(error)")
        }
    }
}

@Suite struct DownloadFailureRecoveryTests {
    @Test func onlyAnAddressThatStoppedWorkingIsDead() {
        for status in [403, 410] {
            #expect(DownloadFailure.http(status: status).isDeadLink, "\(status)")
        }
        for status in [400, 401, 404, 416, 429, 500, 502, 503] {
            #expect(!DownloadFailure.http(status: status).isDeadLink, "\(status)")
        }
        let others: [DownloadFailure] = [.network, .outOfSpace, .unexpectedResponse, .incompleteChunk(expected: 10, actual: 3), .mergeInterrupted]
        for failure in others {
            #expect(!failure.isDeadLink, "\(failure)")
        }
    }

    @Test func failuresThatSayNothingAgainstTheDownloadedDataKeepIt() {
        let keeping: [DownloadFailure] = [.outOfSpace, .mergeInterrupted, .fileSystem("x"), .missingParts]
        for failure in keeping {
            #expect(failure.keepsDownloadedData, "\(failure)")
        }
        let discarding: [DownloadFailure] = [
            .http(status: 403), .network, .incompleteChunk(expected: 10, actual: 3), .unexpectedResponse, .noDownloadableFormat,
            .unknownSize, .tooLarge, .liveStream, .mergeFailed("x"),
        ]
        for failure in discarding {
            #expect(!failure.keepsDownloadedData, "\(failure)")
        }
    }

    @Test func aMergeInterruptionSaysWhatToDo() {
        #expect(DownloadFailure.mergeInterrupted.errorDescription == "Interrupted while combining the video and audio. Retry to finish.")
    }

    @Test func interruptionsAreRecognisedInEveryShapeTheyArriveIn() {
        for code in [-11847, -11818, -11819, -11839, -11840] {
            let error = NSError(domain: AVFoundationErrorDomain, code: code)
            #expect(DownloadFailure.isInterrupted(error), "\(code)")
            #expect(DownloadFailure.from(error) == .mergeInterrupted, "\(code)")
            let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11820, userInfo: [NSUnderlyingErrorKey: error])
            #expect(DownloadFailure.isInterrupted(wrapped), "\(code) as the cause of an export failure")
        }
        // The numbers mean this only in AVFoundation's domain, and only these ones do.
        #expect(!DownloadFailure.isInterrupted(NSError(domain: NSCocoaErrorDomain, code: -11847)))
        #expect(!DownloadFailure.isInterrupted(NSError(domain: AVFoundationErrorDomain, code: -11820)))
        #expect(!DownloadFailure.isInterrupted(URLError(.networkConnectionLost)))

        // The walk is bounded.
        var deep = NSError(domain: AVFoundationErrorDomain, code: -11847)
        for _ in 0..<50 { deep = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: deep]) }
        #expect(!DownloadFailure.isInterrupted(deep))
    }
}
