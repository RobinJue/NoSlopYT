import NoSlopKit
import SwiftUI

/// Runs "Connect" for YouTube recommendations (YouTube's TV sign-in with a code) for the Library row and the Settings
/// section, so both show the same code sheet and the same error message.
///
/// The code is shown as soon as it exists (`prompt`); the polling for the approval runs in a task of its own that
/// `cancel()` ends. Nothing here touches the Google account.
@MainActor
@Observable
final class RecommendationsConnectFlow {
    /// The code to show; non-nil while the sheet is open.
    private(set) var prompt: TVSignInPrompt?
    private(set) var isWorking = false
    /// A plain sentence, shown in an alert; nil when there is nothing to say.
    var errorMessage: String?

    @ObservationIgnored private var poll: Task<TVAccount, any Error>?
    @ObservationIgnored private var restartRequested = false
    @ObservationIgnored private var cancelRequested = false

    func connect(using env: AppEnvironment) async {
        guard !isWorking else { return }
        isWorking = true
        cancelRequested = false
        defer {
            isWorking = false
            prompt = nil
            poll = nil
        }
        do {
            let issued = try await env.recommendationsAuth.beginSignIn()
            guard !cancelRequested else { return }
            prompt = issued
            while true {
                let auth = env.recommendationsAuth
                let task = Task { try await auth.completeSignIn(issued) }
                poll = task
                do {
                    let account = try await task.value
                    env.recommendationsConnected(account)
                    return
                } catch {
                    if isCancellation(error), restartRequested, !cancelRequested {
                        restartRequested = false
                        continue
                    }
                    throw error
                }
            }
        } catch {
            if isCancellation(error) || cancelRequested { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Ends the sign-in (Cancel, or the sheet was closed).
    func cancel() {
        cancelRequested = true
        restartRequested = false
        poll?.cancel()
    }

    /// The app is active again: asks for the approval right away instead of waiting out the polling interval.
    func pollNow() {
        guard prompt != nil, let poll else { return }
        restartRequested = true
        poll.cancel()
    }

    private func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case NoSlopError.cancelled = error { return true }
        return false
    }
}
