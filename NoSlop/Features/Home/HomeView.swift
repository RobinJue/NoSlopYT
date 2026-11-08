import NoSlopKit
import SwiftUI

/// "For you": a "Continue watching" row and a feed of videos: YouTube's own Home when the recommendations connection is
/// on, else a mix computed on the device from the watch history, related videos and fresh uploads of the subscriptions.
/// Nothing to show yet → a welcome card with topic chips.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HomeViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.youTubeFellBack {
                    RefreshFailureBanner(
                        title: "Showing the mix made on this device.",
                        message: "YouTube's Home didn't load."
                    ) {
                        await model.refresh(using: env)
                    }
                    .padding(.horizontal, Theme.padding)
                }
                content
            }
            .padding(.vertical, Theme.padding)
        }
        .refreshable {
            // Titles whose De-clickbait lookup failed are asked again, also the ones that stay on screen.
            DeArrowTitleCache.shared.retryFailedLookups()
            await model.refresh(using: env)
        }
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
        .task {
            #if DEBUG
            DebugLaunchHooks.prepareLaunch(in: env)
            #endif
            model.loadIfNeeded(using: env)
        }
        // Coming back from the full-screen player: "Continue watching" has a new first entry.
        .onChange(of: env.player.presentation) { _, presentation in
            if presentation != .expanded {
                model.loadIfNeeded(using: env)
            }
        }
        // Coming back to the app after hours in the background (it stays alive for days): the feed is looked at again, and
        // rebuilt when it is past its age, as it is when the tab is opened. While a video is on screen it waits for the
        // player to go away (above); a tab that is not showing waits for its `.task`.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, env.router.selectedTab == .home, env.player.presentation != .expanded {
                model.loadIfNeeded(using: env)
            }
        }
        // "Don't show this channel" (or any other feed filter) takes effect on what is on screen, not after a reload.
        .onChange(of: env.settings) {
            model.applyFilter(using: env)
            // The "Show YouTube's Home" switch is a setting too.
            model.sourceMayHaveChanged(using: env)
        }
        // Connected, disconnected, or the account read at launch: Home loads from the right source.
        .onChange(of: HomeCardDismissals.shared.ids) {
            model.cardDismissed(using: env)
        }
        .onChange(of: env.recommendationsRevision) {
            model.sourceMayHaveChanged(using: env)
        }
        .onChange(of: env.recommendationsAccount) {
            model.sourceMayHaveChanged(using: env)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hasContent {
            VStack(alignment: .leading, spacing: 24) {
                if !model.continueWatching.isEmpty {
                    ContinueWatchingRow(entries: model.continueWatching)
                }
                if !model.forYou.isEmpty {
                    feed
                } else if model.phase != .loaded {
                    // "Continue watching" is from the device; the feed is still being built.
                    PlaceholderList(style: .cards, count: 2)
                } else if model.relatedUnavailable {
                    // Nothing to suggest because YouTube could not be asked, which is not the same as being done.
                    RefreshFailureBanner(
                        title: "Couldn't reach YouTube",
                        message: "Suggestions need a connection. Showing what is on this device."
                    ) {
                        await model.refresh(using: env)
                    }
                    .padding(.horizontal, Theme.padding)
                } else {
                    Text("That's everything for now. Search for something or subscribe to channels to fill this feed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.padding)
                }
            }
        } else if model.phase == .loaded {
            emptyState
        } else {
            PlaceholderList(style: .cards)
        }
    }

    @ViewBuilder
    private var feed: some View {
        FeedGrid {
            ForEach(model.forYou) { video in
                Button {
                    env.open(video)
                } label: {
                    VideoCardView(video: video)
                }
                .buttonStyle(.pressableCard)
                .videoContextMenu(video, homeCard: model.showsYouTube)
                .onAppear { model.rowAppeared(video, using: env) }
            }
        }
        if model.showsYouTube, model.youTubePages.hasMore || model.youTubePages.loadMoreError != nil {
            FeedFooter(
                error: model.youTubePages.loadMoreError,
                retry: { model.retryLoadMore(using: env) },
                onReachEnd: { model.loadMore(using: env) },
                isPaused: model.youTubePages.isPaused
            )
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
            env.router.showRoot(of: .library)
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
