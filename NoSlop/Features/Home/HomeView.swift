import NoSlopKit
import SwiftUI

/// "For you": a "Continue watching" row and a feed of videos computed on the device from the watch history, related
/// videos and fresh uploads of the subscriptions. Nothing to show yet → a welcome card with topic chips.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = HomeViewModel()

    var body: some View {
        ScrollView {
            content
                .padding(.vertical, Theme.padding)
        }
        .refreshable { await model.refresh(using: env) }
        .miniPlayerClearance()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        // The wordmark takes the title's place.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Wordmark()
            }
            .hidingSharedBackground()

            ToolbarItem(placement: .topBarTrailing) {
                AccountButton()
            }
        }
        .task { model.loadIfNeeded(using: env) }
        // Coming back from the full-screen player: "Continue watching" has a new first entry.
        .onChange(of: env.player.presentation) { _, presentation in
            if presentation != .expanded {
                model.loadIfNeeded(using: env)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hasContent {
            VStack(alignment: .leading, spacing: 24) {
                if !model.continueWatching.isEmpty {
                    ContinueWatchingRow(entries: model.continueWatching)
                }
                if model.forYou.isEmpty {
                    Text("That's everything for now. Search for something or subscribe to channels to fill this feed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.padding)
                } else {
                    feed
                }
            }
        } else if model.phase == .loaded {
            emptyState
        } else {
            PlaceholderList(style: .cards)
        }
    }

    private var feed: some View {
        FeedGrid {
            ForEach(model.forYou) { video in
                Button {
                    env.open(video)
                } label: {
                    VideoCardView(video: video)
                }
                .buttonStyle(.pressableCard)
                .videoContextMenu(video)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if env.library.subscriptions.isEmpty && env.library.history.isEmpty {
            WelcomeCardView()
                .padding(.horizontal, Theme.padding)
        } else {
            ContentUnavailableView {
                Label("Nothing to show yet", systemImage: "play.slash")
            } description: {
                Text("Your subscriptions have no recent uploads, or YouTube can't be reached. Pull down to refresh.")
            } actions: {
                Button("Refresh") {
                    Task { await model.refresh(using: env) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        }
    }
}

/// The app's name in the navigation bar, with the mark of the app icon.
private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            BrandMarkView(size: 26)
            Text("No Slop")
                .font(.title3.weight(.heavy))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The account avatar (or a person glyph when signed out); it opens the Library tab, where the account lives.
private struct AccountButton: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Button {
            env.router.selectedTab = .library
        } label: {
            if let pictureURL = env.googleAccount?.pictureURL {
                ChannelAvatarView(url: pictureURL, size: 30)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
            }
        }
        .accessibilityLabel(env.googleAccount == nil ? "Account, signed out" : "Account")
        .accessibilityHint("Opens the Library")
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environment(AppEnvironment.preview())
}
