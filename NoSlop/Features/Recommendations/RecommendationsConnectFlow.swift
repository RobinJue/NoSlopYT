import NoSlopKit
import SwiftUI

/// Runs "Connect" for YouTube recommendations (YouTube's TV sign-in with a code) for the Library row and the Settings
/// section, so both show the same code sheet and the same error message.
///
/// The code is shown as soon as it exists (`prompt`); the polling for the approval runs in a task of its own that
/// `cancel()` ends. Only the person ends it (Cancel, or the sheet swiped away): the app going to the background while
/// they approve the code on Google's page must not, so nothing about the sheet appearing or disappearing may call
/// `cancel()`. Nothing here touches the Google account.
@MainActor
@Observable
final class RecommendationsConnectFlow {
    /// The code to show; non-nil while the sheet is open (also while it says why the sign-in failed).
    private(set) var prompt: TVSignInPrompt?
    private(set) var isWorking = false
    /// Why the sign-in failed after the code was shown, a plain sentence the open sheet shows; nil otherwise.
    private(set) var failure: String?
    /// A plain sentence, shown in an alert when no sheet is open (the sign-in could not even start); nil when there is
    /// nothing to say.
    var errorMessage: String?

    @ObservationIgnored private var poll: Task<TVAccount, any Error>?
    @ObservationIgnored private var restartRequested = false
    @ObservationIgnored private var cancelRequested = false

    func connect(using env: AppEnvironment) async {
        guard !isWorking else { return }
        isWorking = true
        cancelRequested = false
        TVTrace.log("flow: connect begins")
        defer {
            TVTrace.log("flow: connect ends (failure shown \(failure != nil), alert set \(errorMessage != nil))")
            isWorking = false
            // A failure stays on the open sheet; anything else (connected, cancelled) closes it.
            if failure == nil || cancelRequested {
                failure = nil
                prompt = nil
            }
            poll = nil
        }
        do {
            let issued = try await env.recommendationsAuth.beginSignIn()
            TVTrace.log("flow: code issued, cancelRequested \(cancelRequested)")
            guard !cancelRequested else { return }
            // A new code replaces the sheet's failure (on "Try again" the failure stays up until this point).
            failure = nil
            prompt = issued
            while true {
                let auth = env.recommendationsAuth
                let task = Task { try await auth.completeSignIn(issued) }
                poll = task
                TVTrace.log("flow: waiting for the approval")
                do {
                    let account = try await task.value
                    TVTrace.log("flow: approved, connecting the app")
                    await env.recommendationsConnected(account)
                    TVTrace.log("flow: app connected")
                    return
                } catch {
                    TVTrace.log("flow: the wait ended, \(TVTrace.describe(error)), restartRequested \(restartRequested), cancelRequested \(cancelRequested)")
                    if isCancellation(error), restartRequested, !cancelRequested {
                        restartRequested = false
                        continue
                    }
                    throw error
                }
            }
        } catch {
            if isCancellation(error) || cancelRequested {
                TVTrace.log("flow: ended without a message (cancelled)")
                return
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // With the sheet open the message goes on the sheet: an alert asked for while a sheet closes is lost.
            if prompt != nil { failure = message } else { errorMessage = message }
            TVTrace.log("flow: failure set, on the sheet \(prompt != nil)")
        }
    }

    /// Ends the sign-in (Cancel, or the sheet was closed).
    func cancel(_ source: String = "unknown") {
        TVTrace.log("flow: cancel from \(source)")
        cancelRequested = true
        restartRequested = false
        poll?.cancel()
        // A sheet that only says why it failed has nothing running to end: closing it clears it.
        if !isWorking {
            prompt = nil
            failure = nil
        }
    }

    /// The app is active again: asks for the approval right away instead of waiting out the polling interval.
    func pollNow() {
        guard prompt != nil, let poll else {
            TVTrace.log("flow: pollNow ignored (prompt \(prompt != nil))")
            return
        }
        TVTrace.log("flow: pollNow, restarting the wait")
        restartRequested = true
        poll.cancel()
    }

    private func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case NoSlopError.cancelled = error { return true }
        return false
    }
}
