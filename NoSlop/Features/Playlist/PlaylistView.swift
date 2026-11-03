import NoSlopKit
import SwiftUI

/// A public YouTube playlist: header with "Play all", then the videos as rows that page in as you scroll. Tapping a
/// video plays it with the videos after it queued, like "Play all" from there.
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
            }
        }
    }

    @ViewBuilder
    private var videos: some View {
        let list = model.list
        if !list.items.isEmpty {
            ForEach(list.items) { video in
                Button {
                    env.open(video, queue: model.videos(after: video))
                } label: {
                    VideoRowView(video: video)
                        .padding(.horizontal, Theme.padding)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.pressableCard)
                .videoContextMenu(video)
                .onAppear { model.rowAppeared(video, using: env) }
            }

            if list.hasMore || list.loadMoreError != nil {
                FeedFooter(
                    error: list.loadMoreError,
                    retry: { model.retryLoadMore(using: env) },
                    onReachEnd: { model.loadMore(using: env) }
                )
            }
        } else if let error = list.loadMoreError {
            ErrorStateView(error: error) { model.retryLoadMore(using: env) }
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

    /// Plays the first video and queues the others.
    private func playAll() {
        guard let first = model.list.items.first else { return }
        env.open(first, queue: Array(model.list.items.dropFirst()))
    }
}

#Preview {
    NavigationStack {
        PlaylistView(playlistID: SampleData.playlist.id)
    }
    .environment(AppEnvironment.preview())
}
