import NoSlopKit
import SwiftUI

/// A notice above content that is still on screen (or where it should be): a warning sign, a title, one line of
/// explanation and a Retry button. "Couldn't refresh. Showing the last feed." is the usual one: a refresh failed while
/// an older feed or list stays.
///
/// At accessibility text sizes the three stack up, so that the texts have the whole width instead of what the sign and
/// the button leave them, which breaks words in the middle.
struct RefreshFailureBanner: View {
    let title: String
    let message: String
    let retry: @MainActor () async -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// "Couldn't refresh", with the plain-language message of `error` (every `NoSlopError` has one) or `fallback`.
    init(
        error: Error,
        fallback: String = "Showing the last feed.",
        retry: @escaping @MainActor () async -> Void
    ) {
        self.init(
            title: "Couldn't refresh",
            message: (error as? LocalizedError)?.errorDescription ?? fallback,
            retry: retry
        )
    }

    init(title: String, message: String, retry: @escaping @MainActor () async -> Void) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: Theme.padding))

        layout {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !stacked {
                Spacer(minLength: 0)
            }
            Button("Retry") {
                Task { await retry() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(Theme.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

#Preview {
    VStack(spacing: 16) {
        RefreshFailureBanner(error: NoSlopError.network("offline")) {}
        RefreshFailureBanner(title: "Couldn't reach YouTube", message: "Suggestions need a connection.") {}
    }
    .padding()
}
