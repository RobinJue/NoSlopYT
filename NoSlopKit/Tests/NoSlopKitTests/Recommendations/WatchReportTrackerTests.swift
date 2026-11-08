import Foundation
import Testing
@testable import NoSlopKit

private enum Seen: Equatable {
    case qualified(Double)
    case progress(Double)
    case ended(Double, Bool)

    init(_ event: WatchEvent) {
        switch event {
        case .qualified(let p): self = .qualified(p)
        case .progress(let p): self = .progress(p)
        case .ended(let p, let f): self = .ended(p, f)
        }
    }
}

/// Plays `seconds` of media in 0.5 s ticks starting at `from`; returns what the tracker said.
private func play(_ tracker: inout WatchReportTracker, from: Double, seconds: Double) -> [Seen] {
    var seen: [Seen] = []
    var position = from
    let steps = Int(seconds / 0.5)
    for _ in 0..<steps {
        position += 0.5
        if let event = tracker.tick(position: position, isPlaying: true) { seen.append(Seen(event)) }
    }
    return seen
}

@Suite("WatchReportTracker")
struct WatchReportTrackerTests {
    @Test func thirtySecondsOfPlayingQualifyOnce() {
        var tracker = WatchReportTracker(lengthSeconds: 600, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        let seen = play(&tracker, from: 0, seconds: 29.5)
        #expect(seen.isEmpty)
        let more = play(&tracker, from: 29.5, seconds: 20)
        #expect(more == [.qualified(30)])
    }

    @Test func seeksAndSkipsDoNotCount() {
        var tracker = WatchReportTracker(lengthSeconds: 600, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        _ = play(&tracker, from: 0, seconds: 20)
        #expect(tracker.tick(position: 80, isPlaying: true).map(Seen.init) == nil)
        #expect(tracker.tick(position: 20, isPlaying: true).map(Seen.init) == nil)
        // 20 s played so far; 9 more seconds is still short of 30.
        #expect(play(&tracker, from: 20, seconds: 9.5).isEmpty)
        #expect(play(&tracker, from: 29.5, seconds: 0.5).count == 1)
    }

    @Test func pausesDoNotCount() {
        var tracker = WatchReportTracker(lengthSeconds: 600, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        _ = play(&tracker, from: 0, seconds: 20)
        for _ in 0..<200 { #expect(tracker.tick(position: 20, isPlaying: false).map(Seen.init) == nil) }
        #expect(play(&tracker, from: 20, seconds: 9.5).isEmpty)
        #expect(play(&tracker, from: 29.5, seconds: 0.5) == [.qualified(30)])
    }

    @Test func aShortVideoQualifiesAtItsEnd() {
        var tracker = WatchReportTracker(lengthSeconds: 12, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        let seen = play(&tracker, from: 0, seconds: 12)
        #expect(seen == [.qualified(11.5)])
        #expect(tracker.closing(position: 12).map(Seen.init) == .ended(12, true))
    }

    @Test func liveStreamsAndShortsNeverReport() {
        var live = WatchReportTracker(lengthSeconds: 0, isLive: true, isShort: false)
        var short = WatchReportTracker(lengthSeconds: 40, isLive: false, isShort: true)
        #expect(play(&live, from: 0, seconds: 120).isEmpty)
        #expect(play(&short, from: 0, seconds: 40).isEmpty)
        #expect(live.closing(position: 120).map(Seen.init) == nil)
        #expect(short.closing(position: 40).map(Seen.init) == nil)
    }

    @Test func progressEveryFourMinutes() {
        var tracker = WatchReportTracker(lengthSeconds: 3600, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        let seen = play(&tracker, from: 0, seconds: 530)
        #expect(seen == [.qualified(30), .progress(270), .progress(510)])
    }

    @Test func closingSaysFinishedInTheLastFivePercent() {
        var tracker = WatchReportTracker(lengthSeconds: 100, isLive: false, isShort: false)
        #expect(tracker.closing(position: 10).map(Seen.init) == nil) // never qualified
        _ = tracker.tick(position: 0, isPlaying: true)
        _ = play(&tracker, from: 0, seconds: 40)
        #expect(Seen(tracker.closing(position: 40)!) == .ended(40, false))
        #expect(Seen(tracker.closing(position: 94.9)!) == .ended(94.9, false))
        #expect(Seen(tracker.closing(position: 95)!) == .ended(95, true))
    }

    @Test func lateKnownLengthKeepsTheCountedTime() {
        var tracker = WatchReportTracker(lengthSeconds: 0, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        #expect(play(&tracker, from: 0, seconds: 20).isEmpty)
        tracker.setLength(600)
        // 20 s were counted before the length arrived, so 10 s more qualify.
        #expect(play(&tracker, from: 20, seconds: 10) == [.qualified(30)])
    }

    @Test func lateKnownLengthStillAllowsTheShortVideoEnd() {
        var tracker = WatchReportTracker(lengthSeconds: 0, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        #expect(play(&tracker, from: 0, seconds: 10).isEmpty)
        tracker.setLength(12)
        #expect(play(&tracker, from: 10, seconds: 2) == [.qualified(11.5)])
    }

    @Test func aFlushReportsWithoutEndingTheViewing() {
        var tracker = WatchReportTracker(lengthSeconds: 3000, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        #expect(tracker.flush(position: 10) == nil) // not qualified yet
        _ = play(&tracker, from: 0, seconds: 40)
        #expect(Seen(tracker.flush(position: 40)!) == .progress(40))
        // The viewing is still open: the next progress comes 240 s of playing after the flush, the end still ends it.
        #expect(play(&tracker, from: 40, seconds: 239.5).isEmpty)
        #expect(play(&tracker, from: 279.5, seconds: 0.5) == [.progress(280)])
        #expect(Seen(tracker.closing(position: 2900)!) == .ended(2900, true))
    }

    @Test func theRangeStartsWhereTheStretchBeganAndMovesWithEachReport() {
        var tracker = WatchReportTracker(lengthSeconds: 3000, isLive: false, isShort: false)
        _ = tracker.tick(position: 600, isPlaying: true)
        let seen = play(&tracker, from: 600, seconds: 30)
        #expect(seen == [.qualified(630)])
        #expect(tracker.reportedFrom == 600)
        // Playing on: the next range begins where the last one ended.
        _ = play(&tracker, from: 630, seconds: 240)
        #expect(tracker.reportedFrom == 630)
        #expect(tracker.closingFrom(position: 870) == 870)
        _ = play(&tracker, from: 870, seconds: 10)
        #expect(tracker.closingFrom(position: 880) == 870)
    }

    @Test func aSeekStartsANewRange() {
        var tracker = WatchReportTracker(lengthSeconds: 3000, isLive: false, isShort: false)
        _ = tracker.tick(position: 0, isPlaying: true)
        _ = play(&tracker, from: 0, seconds: 30)
        _ = play(&tracker, from: 30, seconds: 10)
        _ = tracker.tick(position: 1000, isPlaying: true) // skip ahead
        #expect(tracker.flush(position: 1000) == nil) // nothing played since the skip
        _ = play(&tracker, from: 1000, seconds: 5)
        #expect(tracker.closingFrom(position: 1005) == 1000)
        #expect(Seen(tracker.flush(position: 1005)!) == .progress(1005))
        #expect(tracker.reportedFrom == 1000)
        // A seek back, paused: the stretch starts where playing goes on.
        _ = tracker.tick(position: 200, isPlaying: false)
        _ = tracker.tick(position: 200, isPlaying: true)
        _ = play(&tracker, from: 200, seconds: 3)
        #expect(tracker.closingFrom(position: 203) == 200)
    }
}
