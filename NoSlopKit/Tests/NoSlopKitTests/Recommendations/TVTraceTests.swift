import Foundation
import Testing
@testable import NoSlopKit

@Suite struct TVTraceTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "tvtrace-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "trace.txt")
    }

    @Test func linesAreKeptInTheFileAndReadBackByTheNextLaunch() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let first = TVTrace.Sink()
        first.keep(in: file)
        first.append("one")
        first.append("two")

        let second = TVTrace.Sink()
        second.keep(in: file)
        second.append("three")
        #expect(second.snapshot() == ["one", "two", "three"])
        #expect(first.snapshot() == ["one", "two"])
    }

    @Test func theTraceStaysShortAndKeepsTheNewestLines() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let sink = TVTrace.Sink()
        sink.keep(in: file)
        for number in 1...450 { sink.append("line \(number)") }

        let lines = sink.snapshot()
        #expect(lines.count <= 200)
        #expect(lines.last == "line 450")
        let stored = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(stored.count == lines.count)
        #expect(stored.last == "line 450")
    }

    @Test func aTraceWithoutAFileStillKeepsLinesInMemory() {
        let sink = TVTrace.Sink()
        sink.append("only in memory")
        #expect(sink.snapshot() == ["only in memory"])
    }

    @Test func oauthNamesAreKeptOnlyWhenTheyLookLikeOne() {
        #expect(TVTrace.oauthName("authorization_pending") == "authorization_pending")
        #expect(TVTrace.oauthName(nil) == "none")
        #expect(TVTrace.oauthName("has a space") == "other")
        #expect(TVTrace.oauthName("https://example.com/x") == "other")
        #expect(TVTrace.oauthName(String(repeating: "a", count: 41)) == "other")
    }

    @Test func aForeignErrorShowsOnlyItsDomainAndCode() {
        let foreign = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "secret-looking text"])
        #expect(TVTrace.describe(foreign) == "NSURLErrorDomain#-1009")
        #expect(TVTrace.describe(CancellationError()) == "CancellationError")
        #expect(TVTrace.describe(NoSlopError.oauth("The code expired. Start again.")).contains("The code expired. Start again."))
    }
}
