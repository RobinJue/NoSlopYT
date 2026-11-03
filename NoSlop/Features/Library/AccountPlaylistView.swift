import NoSlopKit
import SwiftUI

/// One playlist of the signed-in YouTube account: its videos, loaded page by page. A row plays that video and
/// queues the ones after it. The summary from the playlist list is enough to draw the header at once.
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
                    await model.reload(from: source)
                }
            case .loaded:
                if model.videos.isEmpty {
                    EmptyStateView(
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
        .task { await model.loadIfNeeded(from: source) }
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
                LibraryPlayAllButton(videos: videos)
            }
            .listRowSeparator(.hidden)

            // Offsets, not video ids: a playlist may hold the same video twice.
            ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
                LibraryVideoRow(video: video) {
                    env.open(video, queue: Array(videos[(index + 1)...]))
                }
                .listRowSeparator(.hidden)
                .onAppear {
                    Task { await model.loadMoreIfNeeded(at: index, from: source) }
                }
            }

            AccountVideosFooter(model: model, source: source)
        }
        .listStyle(.plain)
        .refreshable { await model.reload(from: source) }
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

    private var source: AccountVideosModel.PageSource {
        { token in try await env.account.playlistItems(playlistID: playlist.id, pageToken: token) }
    }
}

#Preview {
    NavigationStack {
        AccountPlaylistView(playlist: SampleData.playlist)
    }
    .environment(AppEnvironment.preview())
}
