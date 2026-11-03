import NoSlopKit
import OSLog
import UIKit

/// Gets the library onto disk when the app leaves the foreground.
///
/// `LibraryStore` writes its files 0.5 s after the first change. iOS suspends an app moments after it leaves the
/// foreground and may end it later without a word, so whatever changed in the last half second would be lost.
/// `persist` writes the library at once and holds a background task open until the files are on disk, which asks iOS
/// to keep the app running that long.
@MainActor
enum BackgroundPersistence {
    /// Flushes `library` inside a background task. Call it on the main actor at the moment the app leaves the
    /// foreground: the task has to begin before the app is suspended, so nothing may be awaited before it.
    ///
    /// The task ends when the flush returns or when iOS says the time is up, whichever comes first, and never twice.
    static func persist(_ library: LibraryStore) {
        let request = BackgroundTimeRequest(name: "Save library")
        Task {
            await library.flush()
            request.end()
        }
    }
}

/// One UIKit background task, which ends exactly once: when the work calls `end()`, or when iOS runs out of patience
/// and calls the expiration handler, whichever comes first. A task that is never ended gets the whole app terminated.
@MainActor
final class BackgroundTimeRequest {
    private static let log = Logger(subsystem: "com.robinjungerich.noslopyt", category: "background-task")

    private let name: String
    private var identifier = UIBackgroundTaskIdentifier.invalid

    /// Begins the task. `.invalid` (iOS refused, for example because the app is out of background time) leaves
    /// nothing to end; the work then simply runs without the extra time.
    init(name: String) {
        self.name = name
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.expire()
        }
        Self.log.debug("began \(name, privacy: .public)")
    }

    /// Ends the task. Later calls do nothing.
    func end() {
        guard identifier != .invalid else { return }
        let finished = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(finished)
        Self.log.debug("ended \(self.name, privacy: .public)")
    }

    /// iOS is about to suspend the app whatever the work is doing; ending the task is what keeps the app from being
    /// terminated for overstaying.
    private func expire() {
        Self.log.error("Background time for \(self.name, privacy: .public) ran out before the work finished")
        end()
    }
}
