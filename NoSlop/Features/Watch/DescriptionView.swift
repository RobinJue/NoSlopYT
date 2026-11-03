import NoSlopKit
import SwiftUI

/// The description card on the watch page. Collapsed it shows three lines of plain text and expands on a tap;
/// expanded it shows the whole text with tappable links:
///
/// - timestamps seek the player,
/// - video links open that video in the player,
/// - channel and playlist links open the channel or playlist,
/// - hashtags search for the tag,
/// - web addresses open in the browser (YouTube links open in the app).
struct DescriptionView: View {
    let description: AttributedDescription

    @Environment(AppEnvironment.self) private var env
    @State private var isExpanded = false

    var body: some View {
        if description.text.isEmpty {
            EmptyView()
        } else if isExpanded {
            expanded
        } else {
            collapsed
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        Button {
            withAnimation(.snappy) { isExpanded = true }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(description.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text("Show more")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.padding)
            .background(card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the whole description")
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(DescriptionText.attributedString(for: description))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in handle(url) })

            Button("Show less") {
                withAnimation(.snappy) { isExpanded = false }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(Theme.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .fill(Color(.secondarySystemFill))
    }

    // MARK: Links

    private func handle(_ url: URL) -> OpenURLAction.Result {
        guard let target = DescriptionText.target(for: url, in: description) else {
            // Not one of ours: let the system open it.
            return .systemAction
        }
        switch target {
        case .timestamp(let seconds):
            env.player.seek(to: Double(seconds))
        case .video(let id, let startSeconds):
            open(DescriptionText.watchLink(id: id, startSeconds: startSeconds))
        case .channel(let id):
            env.show(.channel(id: id))
        case .playlist(let id):
            env.show(.playlist(id: id))
        case .hashtag(let tag):
            env.show(.searchResults(query: DescriptionText.hashtagQuery(tag)))
        case .url(let address):
            if YouTubeURL.resolveLocally(address) != nil {
                open(address)
            } else {
                return .systemAction(address)
            }
        }
        return .handled
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        Task { await env.handleOpenURL(url) }
    }
}

#Preview {
    ScrollView {
        DescriptionView(description: SampleData.details(for: SampleData.videos[3]).description)
            .padding()
    }
    .environment(AppEnvironment.preview())
}
