import NoSlopKit
import SwiftUI

/// The end of a list that loads in pages: a spinner while the next page is on its way, or "Couldn't load more" with
/// Retry when it failed. Reaching it also asks for the next page (`onReachEnd`), so a list that is shorter than the
/// screen still pages in.
struct FeedFooter: View {
    let error: Error?
    let retry: () -> Void
    var onReachEnd: () -> Void = {}

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
            } else {
                ProgressView()
                    .accessibilityLabel("Loading more")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .onAppear(perform: onReachEnd)
    }
}

#Preview("Footer") {
    VStack {
        FeedFooter(error: nil, retry: {})
        FeedFooter(error: NoSlopError.network("offline"), retry: {})
    }
}
