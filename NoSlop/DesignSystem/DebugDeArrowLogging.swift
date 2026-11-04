#if DEBUG
import NoSlopKit
import OSLog

/// What the title views and the player ask of DeArrow, written to the log (category `deArrow`, lines that start with
/// "[deArrow]"), for simulator checks. Mock runs wrap their DeArrow service in it. Compiled out of Release builds.
///
///     xcrun simctl spawn <udid> log show --last 2m --info --debug --predicate 'category == "deArrow"'
///
/// A lookup runs in a task of its own, as the real client's request does (`DeArrowClient`): a card that scrolls off the
/// screen cancels the task that asked, not the request, and the answer still arrives. Without this the mock would end the
/// moment its asker is cancelled, which is not how the real service behaves, and the case that matters (a lookup that fails
/// after its card has gone) could not be seen. `-deArrowDelay <seconds>` sets how long a lookup takes.
nonisolated struct LoggingDeArrow: DeArrowProviding {
    private static let logger = Logger(subsystem: "com.robinjungerich.noslopyt", category: "deArrow")

    let base: any DeArrowProviding

    init(_ base: any DeArrowProviding) {
        self.base = base
    }

    func betterTitle(videoID: String) async -> String? {
        if case .title(let title) = await lookup(videoID: videoID) { return title }
        return nil
    }

    func lookup(videoID: String) async -> DeArrowLookup {
        Self.logger.info("[deArrow] lookup \(videoID, privacy: .public) start")
        let base = base
        let result = await Task { await base.lookup(videoID: videoID) }.value
        Self.logger.info("[deArrow] lookup \(videoID, privacy: .public) -> \(String(describing: result), privacy: .public)")
        return result
    }
}
#endif
