import Foundation
import NoSlopKit

/// The player's side of reporting watched videos to the connected YouTube account. The player never waits for any of
/// this: every call here returns at once and the work runs on a utility task.
extension AppEnvironment {
    /// Hands the report closure and the network trigger to the player.
    func installWatchReportHooks() {
        let reporter = watchReporter
        player.watchReport = { event, viewing in
            Task(priority: .utility) { await reporter.record(event, for: viewing) }
        }
        player.networkCameBack = { [weak self] in self?.replayWatchReports() }
    }

    /// Sends the reports that were kept (launch, app active, network back, after the YouTube Home loaded).
    func replayWatchReports() {
        let reporter = watchReporter
        Task(priority: .utility) { await reporter.replayPending() }
    }
}
