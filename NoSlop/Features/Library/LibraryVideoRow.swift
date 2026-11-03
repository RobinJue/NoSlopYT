import NoSlopKit
import SwiftUI

/// A video in one of the Library lists (history, Watch Later, playlists, liked videos): the compact row, a tap that
/// plays it, and the long-press menu. `play` is a closure, not a queue, so a long list does not build a queue per row.
struct LibraryVideoRow: View {
    let video: VideoSummary
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VideoRowView(video: video)
        }
        .buttonStyle(.plain)
        .videoContextMenu(video)
    }
}

/// "Play all" at the top of a playlist-like screen: starts the first video and queues the rest.
struct LibraryPlayAllButton: View {
    let videos: [VideoSummary]

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Button {
            guard let first = videos.first else { return }
            env.open(first, queue: Array(videos.dropFirst()))
        } label: {
            Label("Play all", systemImage: "play.fill")
                .labelStyle(.tight)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(videos.isEmpty)
    }
}
