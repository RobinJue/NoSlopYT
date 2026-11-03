import NoSlopKit
import SwiftUI

/// What Home shows when there is nothing to recommend yet (no history, no subscriptions): a short welcome, ways to
/// get started (search, sign in) and topic chips that run a search.
struct WelcomeCardView: View {
    @Environment(AppEnvironment.self) private var env

    /// The plan's starter topics; each runs a search for its name.
    static let topics = ["Science", "Music", "Cooking", "Tech", "History", "Travel"]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                BrandMarkView(size: 56)
                Text("Welcome to No Slop")
                    .font(.title2.weight(.bold))
                Text("YouTube without ads, Shorts, sponsor reads or clickbait. Search for something, subscribe to a channel, or sign in to bring your own subscriptions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button {
                    env.router.selectedTab = .search
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if env.googleAccount == nil {
                    Button {
                        env.router.selectedTab = .library
                    } label: {
                        Label("Sign in with Google", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 10) {
                Text("Or start with a topic")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Self.topics, id: \.self) { topic in
                        TopicChip(title: topic) {
                            env.show(.searchResults(query: topic))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: 520)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity)
    }
}

/// A rounded capsule button with a topic name.
private struct TopicChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Search for \(title)")
    }
}

#Preview {
    ScrollView {
        WelcomeCardView().padding()
    }
    .environment(AppEnvironment.preview())
}
