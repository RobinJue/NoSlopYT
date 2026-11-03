import Foundation
import Testing
@testable import NoSlopKit

@Suite struct ChapterLookupTests {
    private let chapters = [
        Chapter(title: "Introduction", startSeconds: 0),
        Chapter(title: "The main part", startSeconds: 60),
        Chapter(title: "Wrap-up", startSeconds: 120),
    ]

    // MARK: From the plan

    @Test func chapterLookup() {
        #expect(ChapterLookup.chapter(at: 59.9, in: chapters)?.title == "Introduction")
        #expect(ChapterLookup.chapter(at: 60, in: chapters)?.title == "The main part")
        #expect(ChapterLookup.chapter(at: 500, in: chapters)?.title == "Wrap-up")
        #expect(ChapterLookup.chapter(at: 10, in: []) == nil)
    }

    // MARK: Edges

    @Test func firstAndLastBoundaries() {
        #expect(ChapterLookup.chapter(at: 0, in: chapters)?.title == "Introduction")
        #expect(ChapterLookup.chapter(at: 119.999, in: chapters)?.title == "The main part")
        #expect(ChapterLookup.chapter(at: 120, in: chapters)?.title == "Wrap-up")
    }

    @Test func timeBeforeTheFirstChapterHasNone() {
        let late = [Chapter(title: "Start", startSeconds: 5), Chapter(title: "Next", startSeconds: 50)]
        #expect(ChapterLookup.chapter(at: 2, in: late) == nil)
        #expect(ChapterLookup.chapter(at: 5, in: late)?.title == "Start")
    }

    @Test func unsortedChaptersStillResolve() {
        let shuffled = [chapters[2], chapters[0], chapters[1]]
        #expect(ChapterLookup.chapter(at: 59.9, in: shuffled)?.title == "Introduction")
        #expect(ChapterLookup.chapter(at: 60, in: shuffled)?.title == "The main part")
        #expect(ChapterLookup.chapter(at: 500, in: shuffled)?.title == "Wrap-up")
    }

    @Test func singleChapterCoversEverythingAfterItsStart() {
        let only = [Chapter(title: "All", startSeconds: 0)]
        #expect(ChapterLookup.chapter(at: 0, in: only)?.title == "All")
        #expect(ChapterLookup.chapter(at: 86_400, in: only)?.title == "All")
    }

    @Test(arguments: [-1.0, Double.nan, -Double.infinity])
    func unusableTimesHaveNoChapter(time: Double) {
        #expect(ChapterLookup.chapter(at: time, in: chapters) == nil)
    }

    @Test func infiniteTimeIsTheLastChapter() {
        #expect(ChapterLookup.chapter(at: .infinity, in: chapters)?.title == "Wrap-up")
    }

    @Test func nonFiniteChapterStartsAreIgnored() {
        let odd = [Chapter(title: "Broken", startSeconds: .nan), Chapter(title: "Fine", startSeconds: 0)]
        #expect(ChapterLookup.chapter(at: 10, in: odd)?.title == "Fine")
    }

    @Test func sampleDataChapters() {
        #expect(ChapterLookup.chapter(at: 61, in: SampleData.chapters)?.title == "The main part")
    }
}
