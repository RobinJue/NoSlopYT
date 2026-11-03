import NoSlopKit
import SwiftUI

/// The end of a list that loads in pages: a spinner while the next page is on its way, or "Couldn't load more" with
/// Retry when it failed. Reaching it also asks for the next page (`onReachEnd`), so a list that is shorter than the
/// screen still pages in. When paging has paused (`FeedPages.isPaused`) nothing is on its way, so instead of a spinner
/// that never ends it offers "Show more", which asks for the next page as well.
struct FeedFooter: View {
    let error: Error?
    let retry: () -> Void
    var onReachEnd: () -> Void = {}
    var isPaused = false

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 6) {
                    Text((error as? LocalizedError)?.errorDescription ?? "Couldn't load more.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, Theme.padding)
            } else if isPaused {
                Button("Show more", action: onReachEnd)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .accessibilityLabel("Loading more")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .onAppear(perform: onReachEnd)
    }
}

/// What a list with no rows shows when paging has paused (`FeedPages.isPaused`): the feed filters hid several pages
/// in a row, and there are more behind them. Loading placeholders would never end, so it says so and offers to go on.
struct FeedPausedView: View {
    let keepLooking: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Nothing to show yet", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Your feed filters hid everything on the pages loaded so far. There may be more further on.")
        } actions: {
            Button("Keep looking", action: keepLooking)
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview("Footer") {
    VStack {
        FeedFooter(error: nil, retry: {})
        FeedFooter(error: NoSlopError.network("offline"), retry: {})
        FeedFooter(error: nil, retry: {}, isPaused: true)
    }
}

#Preview("Paused") {
    FeedPausedView {}
}
