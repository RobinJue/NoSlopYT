import NoSlopKit
import SwiftUI

// The loading, empty and error states every network screen shows.

/// An error with a plain-language message and, optionally, "Retry" and "Open on YouTube".
///
/// The message is `LocalizedError.errorDescription` when the error has one (every `NoSlopError` does), otherwise
/// a generic sentence. "Open on YouTube" appears only when a URL is given. `retry` may be async:
/// `ErrorStateView(error: e) { await model.load() }`.
///
/// There is no "Retry" for an error that says trying again cannot help (`NoSlopError.isWorthRetrying`): a video,
/// playlist or channel that YouTube says is gone would only be asked about again. The screen then says what YouTube
/// said under "Not available", not "Something went wrong".
struct ErrorStateView: View {
    let error: Error
    let retry: (@MainActor () async -> Void)?
    let openURL: URL?

    @Environment(\.openURL) private var openExternally

    init(error: Error, retry: (@MainActor () async -> Void)? = nil, openURL: URL? = nil) {
        self.error = error
        self.retry = retry
        self.openURL = openURL
    }

    /// Same as `init(error:retry:openURL:)` with the URL first, for call sites that read better that way.
    init(error: Error, openURL: URL?, retry: @escaping @MainActor () async -> Void) {
        self.error = error
        self.retry = retry
        self.openURL = openURL
    }

    var body: some View {
        ContentUnavailableView {
            Label(isWorthRetrying ? "Something went wrong" : "Not available", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry, isWorthRetrying {
                Button("Retry") {
                    Task { await retry() }
                }
                .buttonStyle(.borderedProminent)
            }
            if let openURL {
                Button("Open on YouTube") {
                    openExternally(openURL)
                }
            }
        }
    }

    private var message: String {
        (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Please try again."
    }

    private var isWorthRetrying: Bool {
        (error as? NoSlopError)?.isWorthRetrying ?? true
    }
}

/// "Nothing here" with an icon, a title and an optional explanation.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String?

    init(title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        }
    }
}

/// A centred spinner for a screen that is loading for the first time.
struct LoadingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 240)
            .accessibilityLabel("Loading")
    }
}

#Preview("Error") {
    ErrorStateView(error: NoSlopError.network("offline"), retry: {}, openURL: URL(string: "https://www.youtube.com"))
}

#Preview("Gone") {
    ErrorStateView(error: NoSlopError.unavailable(reason: "The playlist does not exist."), retry: {}, openURL: URL(string: "https://www.youtube.com"))
}

#Preview("Empty") {
    EmptyStateView(title: "No videos", systemImage: "play.slash", message: "Subscribe to channels to see their uploads here.")
}

#Preview("Loading") {
    LoadingView()
}
