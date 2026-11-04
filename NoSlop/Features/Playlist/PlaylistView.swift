import NoSlopKit
import SwiftUI

/// A public YouTube playlist: header with "Play all", then the videos as rows that page in as you scroll. Tapping a
/// video plays it with the videos after it queued, like "Play all" from there. Both queue the whole playlist: the part
/// that is not loaded yet (a playlist of 250 videos has loaded about 100) follows page by page while the queue plays.
/// The queue carries the title of the playlist, for the "Playing from ..." section of the watch page.
struct PlaylistView: View {
    let playlistID: String

    @Environment(AppEnvironment.self) private var env
    @State private var model: PlaylistViewModel

    init(playlistID: String) {
        self.playlistID = playlistID
        _model = State(initialValue: PlaylistViewModel(playlistID: playlistID))
    }

    var body: some View {
        ScrollView {
            content
        }
        .refreshable { await model.refresh(using: env) }
        .miniPlayerClearance()
        // The header shows the title in full; a long one would only be cut off up here.
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = model.webURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url)
                }
            }
        }
        .task { model.loadIfNeeded(using: env) }
        #if DEBUG
        .debugPlaylistPlay(isLoaded: debugIsLoaded) { choice in
            switch choice {
            case .all:
                playAll()
            case .row(let number):
                let items = model.list.items
                if number <= items.count { play(items[number - 1]) }
            }
        }
        #endif
        // "Don't show this channel" (or any other feed filter) takes effect on the videos on screen, not after a
        // reload. Also when the screen comes back: the filter may have changed on a screen above it.
        .onChange(of: env.settings) {
            model.filtersChanged(using: env)
        }
        .onAppear {
            model.filtersChanged(using: env)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            VStack(alignment: .leading, spacing: Theme.feedSpacing) {
                PlaylistHeaderPlaceholder()
                PlaceholderList(style: .rows, count: 4)
            }
            .padding(.top, Theme.padding)

        case .failed(let error):
            ErrorStateView(error: error, openURL: model.webURL) { model.retry(using: env) }
                .padding(.top, 60)

        case .loaded:
            if let info = model.info {
                LazyVStack(spacing: 0) {
                    PlaylistHeaderView(
                        info: info,
                        details: model.details,
                        firstVideo: model.list.items.first,
                        playAll: playAll
                    )
                    .padding(.top, Theme.padding)

                    videos
                }
                // Like the other lists: the last row ends `padding` above the end of the page (a row has its own).
                .padding(.bottom, Theme.padding - Self.rowPadding)
            }
        }
    }

    /// Space above and below each video row.
    private static let rowPadding: CGFloat = 6

    @ViewBuilder
    private var videos: some View {
        let list = model.list
        if !list.items.isEmpty {
            ForEach(list.items) { video in
                Button {
                    play(video)
                } label: {
                    VideoRowView(video: video)
                        .padding(.horizontal, Theme.padding)
                        .padding(.vertical, Self.rowPadding)
                }
                .buttonStyle(.pressableCard)
                .videoContextMenu(video)
                .onAppear { model.rowAppeared(video, using: env) }
            }

            if list.hasMore || list.loadMoreError != nil {
                FeedFooter(
                    error: list.loadMoreError,
                    retry: { model.retryLoadMore(using: env) },
                    onReachEnd: { model.loadMore(using: env) },
                    isPaused: list.isPaused
                )
            }
        } else if let error = list.loadMoreError {
            ErrorStateView(error: error) { model.retryLoadMore(using: env) }
                .padding(.top, 30)
        } else if list.isPaused {
            FeedPausedView { model.loadMore(using: env) }
                .padding(.top, 30)
        } else if list.hasMore || list.isLoadingMore {
            PlaceholderList(style: .rows, count: 4)
        } else {
            EmptyStateView(
                title: "No videos",
                systemImage: "play.slash",
                message: "This playlist has no videos to show."
            )
            .padding(.top, 30)
        }
    }

    /// Plays `video` and queues the videos after it, like "Play all" from there. What the playlist has behind the
    /// loaded part is queued page by page as the queue runs low.
    private func play(_ video: VideoSummary) {
        env.open(video, queue: model.videos(after: video), more: model.queueSource(using: env), queueName: model.info?.title)
    }

    /// Plays the first video and queues the others, the whole playlist and not only the part that is loaded.
    private func playAll() {
        guard let first = model.list.items.first else { return }
        env.open(
            first,
            queue: Array(model.list.items.dropFirst()),
            more: model.queueSource(using: env),
            queueName: model.info?.title
        )
    }

    #if DEBUG
    private var debugIsLoaded: Bool {
        if case .loaded = model.phase { return true }
        return false
    }
    #endif
}

#Preview {
    NavigationStack {
        PlaylistView(playlistID: SampleData.playlist.id)
    }
    .environment(AppEnvironment.preview())
}
