import Foundation
import Testing
@testable import NoSlopKit

@Suite("PendingWatchReports")
struct PendingWatchReportsTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString).json")
    }

    private func entry(_ id: String = "abc", at date: Date) -> PendingWatchReport {
        PendingWatchReport(videoID: id, lengthSeconds: 300, position: 42, finished: false, createdAt: date)
    }

    @Test func survivesReopening() {
        let url = tempURL()
        let now = Date()
        let queue = PendingWatchReports(fileURL: url, now: { now })
        let item = entry(at: now)
        queue.add(item)
        let reopened = PendingWatchReports(fileURL: url, now: { now })
        #expect(reopened.all().map(\.id) == [item.id])
        #expect(reopened.all().first?.videoID == "abc")
        reopened.remove(id: item.id)
        #expect(PendingWatchReports(fileURL: url, now: { now }).all().isEmpty)
    }

    @Test func capsAtFiftyKeepingTheNewest() {
        let now = Date()
        let queue = PendingWatchReports(fileURL: tempURL(), now: { now })
        for i in 0..<60 { queue.add(entry("v\(i)", at: now.addingTimeInterval(Double(i)))) }
        let all = queue.all()
        #expect(all.count == 50)
        #expect(all.first?.videoID == "v10")
        #expect(all.last?.videoID == "v59")
    }

    @Test func dropsEntriesOlderThanSevenDays() {
        let now = Date()
        let url = tempURL()
        let queue = PendingWatchReports(fileURL: url, now: { now })
        queue.add(entry("old", at: now.addingTimeInterval(-8 * 86_400)))
        queue.add(entry("fresh", at: now.addingTimeInterval(-6 * 86_400)))
        #expect(queue.all().map(\.videoID) == ["fresh"])
    }

    @Test func aDamagedFileStartsEmptyWithoutCrashing() throws {
        let url = tempURL()
        try Data("{not json".utf8).write(to: url)
        let queue = PendingWatchReports(fileURL: url)
        #expect(queue.all().isEmpty)
        queue.add(entry(at: Date()))
        #expect(queue.all().count == 1)
    }

    @Test func removeAllEmptiesTheFile() {
        let url = tempURL()
        let queue = PendingWatchReports(fileURL: url)
        queue.add(entry(at: Date()))
        queue.removeAll()
        #expect(PendingWatchReports(fileURL: url).all().isEmpty)
    }
}
