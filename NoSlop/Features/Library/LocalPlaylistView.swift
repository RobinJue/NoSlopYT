import NoSlopKit
import SwiftUI

/// A playlist kept on this device. A row plays that video and queues the ones after it; swipe to remove a video;
/// the menu renames or deletes the playlist.
struct LocalPlaylistView: View {
    let playlistID: UUID

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isConfirmingDelete = false

    private var playlist: LocalPlaylist? {
        env.library.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        Group {
            if let playlist {
                content(for: playlist)
            } else {
                EmptyStateView(
                    title: "Playlist not found",
                    systemImage: "music.note.list",
                    message: "It may have been deleted."
                )
            }
        }
        .navigationTitle(playlist?.title ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let playlist {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            draftTitle = playlist.title
                            isRenaming = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label("Delete playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Playlist options")
                    // Attached to the menu button, so the confirmation appears next to it.
                    .confirmationDialog("Delete this playlist?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                        Button("Delete playlist", role: .destructive) {
                            env.library.deletePlaylist(playlistID)
                            dismiss()
                        }
                    } message: {
                        Text("Only the list on this device is removed.")
                    }
                }
            }
        }
        .alert("Rename playlist", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Save") {
                env.library.renamePlaylist(playlistID, title: draftTitle)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func content(for playlist: LocalPlaylist) -> some View {
        if playlist.videos.isEmpty {
            EmptyStateView(
                title: "No videos yet",
                systemImage: "music.note.list",
                message: "Choose Add to playlist in a video's menu to put it here."
            )
        } else {
            let videos = playlist.videos
            List {
                VStack(alignment: .leading, spacing: 10) {
                    Text(videos.count == 1 ? "1 video" : "\(videos.count) videos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LibraryPlayAllButton(videos: videos)
                }
                .listRowSeparator(.hidden)

                ForEach(videos) { video in
                    LibraryVideoRow(video: video) {
                        play(video, in: videos)
                    }
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            env.library.remove(videoID: video.id, fromPlaylist: playlistID)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// Plays `video` and queues the videos after it.
    private func play(_ video: VideoSummary, in videos: [VideoSummary]) {
        guard let index = videos.firstIndex(where: { $0.id == video.id }) else {
            env.open(video)
            return
        }
        env.open(video, queue: Array(videos[(index + 1)...]))
    }
}

#Preview {
    NavigationStack {
        LocalPlaylistView(playlistID: UUID())
    }
    .environment(AppEnvironment.preview())
}
