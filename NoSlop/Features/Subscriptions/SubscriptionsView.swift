import NoSlopKit
import SwiftUI

/// A strip of the subscribed channels' avatars, then the chronological feed of their uploads. Pull to refresh;
/// "Manage" opens the subscriptions manager.
struct SubscriptionsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = SubscriptionsViewModel()

    var body: some View {
        ScrollView {
            content
                .padding(.bottom, Theme.padding)
        }
        .refreshable { await model.refresh(using: env) }
        .miniPlayerClearance()
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Manage") {
                    env.show(.subscriptionsManager)
                }
            }
        }
        .task { model.loadIfNeeded(using: env) }
        // Back from the full-screen player: something may have been watched, which the filters can hide, and the feed
        // may have grown old while the video played.
        .onChange(of: env.player.presentation) { _, presentation in
            if presentation != .expanded {
                model.loadIfNeeded(using: env)
            }
        }
        // Coming back to the app after hours in the background (it stays alive for days): the feed is looked at again,
        // and refreshed when it is past its age, as it is when the tab is opened. While a video is on screen it waits for
        // the player to go away (above); a tab that is not showing waits for its `.task`.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, env.router.selectedTab == .subscriptions, env.player.presentation != .expanded {
                model.loadIfNeeded(using: env)
            }
        }
        // "Don't show this channel" (or any other feed filter) takes effect on what is on screen, not after a reload.
        .onChange(of: env.settings) {
            model.applyFilter(using: env)
        }
    }

    @ViewBuilder
    private var content: some View {
        let subscriptions = env.library.subscriptions
        if subscriptions.isEmpty {
            noSubscriptions
        } else {
            LazyVStack(alignment: .leading, spacing: Theme.feedSpacing) {
                SubscriptionStrip(channels: ordered(subscriptions))
                    .padding(.top, Theme.padding)

                switch model.phase {
                case .idle, .loading:
                    PlaceholderList(style: .cards)
                case .failed(let error):
                    ErrorStateView(error: error) { await model.refresh(using: env) }
                case .loaded:
                    feed
                }
            }
        }
    }

    @ViewBuilder
    private var feed: some View {
        if let failure = model.refreshFailure {
            RefreshFailureBanner(error: failure) { await model.refresh(using: env) }
                .padding(.horizontal, Theme.padding)
        }

        if model.videos.isEmpty {
            if model.hasNoUploads {
                EmptyStateView(
                    title: "No new uploads",
                    systemImage: "play.slash",
                    message: "The channels you subscribe to have not uploaded anything recently."
                )
            } else {
                EmptyStateView(
                    title: "All caught up",
                    systemImage: "checkmark.circle",
                    message: "Your feed filters hide every upload. You can change them in Settings."
                )
            }
        } else {
            FeedGrid {
                ForEach(model.videos) { video in
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
    }

    private var noSubscriptions: some View {
        ContentUnavailableView {
            Label("No subscriptions yet", systemImage: "play.square.stack")
        } description: {
            Text("Subscribe to channels to see their uploads here.")
        } actions: {
            Button("Search for channels") {
                env.router.showRoot(of: .search)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 60)
    }

    /// Channels with the newest uploads first, then the rest in subscription order.
    private func ordered(_ subscriptions: [SubscribedChannel]) -> [SubscribedChannel] {
        let rank = Dictionary(model.channelOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return subscriptions.enumerated()
            .sorted { lhs, rhs in
                switch (rank[lhs.element.id], rank[rhs.element.id]) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}

/// The round avatars of the subscribed channels, in a horizontal row. Tapping one opens the channel.
private struct SubscriptionStrip: View {
    let channels: [SubscribedChannel]

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(channels) { channel in
                    Button {
                        env.show(.channel(id: channel.id))
                    } label: {
                        VStack(spacing: 6) {
                            ChannelAvatarView(url: channel.avatarURL, size: 56)
                            Text(channel.name)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                // Room for two lines on every item, so a long name wraps instead of being cut off and
                                // the (lazy) row has one height whichever channels are on screen.
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.center)
                                .frame(width: 68, alignment: .top)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityLabel(channel.name)
                    .accessibilityHint("Opens the channel")
                }
            }
            .padding(.horizontal, Theme.padding)
        }
    }
}

/// "Couldn't refresh. Showing the last feed." with a Retry button, above a feed that is still on screen.
private struct RefreshFailureBanner: View {
    let error: Error
    let retry: @MainActor () async -> Void

    var body: some View {
        HStack(spacing: Theme.padding) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't refresh")
                    .font(.subheadline.weight(.semibold))
                Text((error as? LocalizedError)?.errorDescription ?? "Showing the last feed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Retry") {
                Task { await retry() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(Theme.padding)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        SubscriptionsView()
    }
    .environment(AppEnvironment.preview())
}
