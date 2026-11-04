import NoSlopKit
import SwiftUI

/// One playlist of the signed-in YouTube account: its videos, loaded page by page and shown through the feed filters
/// (Shorts, blocked channels and words), like every other list. A row plays that video and queues the ones after it, and
/// "Play all" queues the playlist: both go on through the pages that are not loaded yet while the queue plays.
/// The summary from the playlist list is enough to draw the header at once.
struct AccountPlaylistView: View {
    let playlist: PlaylistSummary

    @Environment(AppEnvironment.self) private var env
    @State private var model = AccountVideosModel()

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                LoadingView()
            case .failed(let error):
                ErrorStateView(error: error) {
                    await model.reload(using: loader)
                }
            case .loaded:
                if model.videos.isEmpty {
                    AccountVideosEmptyView(
                        model: model,
                        loader: loader,
                        title: "No videos",
                        systemImage: "list.bullet.rectangle",
                        message: "This playlist is empty, or its videos are private."
                    )
                } else {
                    list
                }
            }
        }
        // The header of the list carries the full title; a long one would only be cut off up here.
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded(using: loader) }
        // "Don't show this channel" (or any other feed filter) takes effect on the videos on screen, not after a
        // reload. Also when the screen comes back: the filter may have changed on a screen above it.
        .onChange(of: env.settings) {
            Task { await model.refilter(using: loader) }
        }
        .onAppear {
            Task { await model.refilter(using: loader) }
        }
    }

    private var list: some View {
        let videos = model.videos
        return List {
            VStack(alignment: .leading, spacing: 10) {
                Text(playlist.title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LibraryPlayAllButton(videos: videos, queueName: playlist.title, more: queueSource)
            }
            .listRowSeparator(.hidden)

            // Offsets, not video ids: a playlist may hold the same video twice.
            ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
                LibraryVideoRow(video: video) {
                    // "Play all" and a row queue the whole playlist: the pages that are not loaded yet follow while it plays.
                    env.open(video, queue: Array(videos[(index + 1)...]), more: queueSource(), queueName: playlist.title)
                }
                .listRowSeparator(.hidden)
                .onAppear {
                    Task { await model.loadMoreIfNeeded(at: index, using: loader) }
                }
            }

            AccountVideosFooter(model: model, loader: loader)
        }
        .listStyle(.plain)
        .miniPlayerClearance()
        .refreshable { await model.reload(using: loader) }
    }

    /// "Channel · 14 videos"
    private var subtitle: String {
        var parts: [String] = []
        if let name = playlist.channel?.name, !name.isEmpty {
            parts.append(name)
        }
        if let text = playlist.videoCountText, !text.isEmpty {
            parts.append(text)
        } else if let count = playlist.videoCount {
            parts.append(count == 1 ? "1 video" : "\(count) videos")
        }
        return parts.joined(separator: " · ")
    }

    /// The pages of the playlist behind what is loaded, for the player's queue; nil when it is loaded to its end. Asked when
    /// the viewer taps, so it starts where the list is by then.
    private func queueSource() -> QueueSource? {
        let playlistID = playlist.id
        return model.queueSource(using: env) { account, token in
            try await account.playlistItems(playlistID: playlistID, pageToken: token)
        }
    }

    /// Where the pages come from, and what the viewer's filters leave out. Built per call, so it follows the settings.
    private var loader: AccountVideosModel.Loader {
        let playlistID = playlist.id
        return AccountVideosModel.Loader(
            source: { token in
                try await env.viaAccount { try await $0.playlistItems(playlistID: playlistID, pageToken: token) }
            },
            filter: { videos in env.contentFilter.filter(videos) }
        )
    }
}

#Preview {
    NavigationStack {
        AccountPlaylistView(playlist: SampleData.playlist)
    }
    .environment(AppEnvironment.preview())
}
