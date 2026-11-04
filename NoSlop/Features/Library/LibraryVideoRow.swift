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
///
/// A list that has pages behind what is loaded (the liked videos, a playlist of the account) passes `more`, which is asked
/// at the tap for the rest of the list, so that the queue goes on through the pages that are not loaded yet. `queueName`
/// is what the watch page calls the list ("Playing from <name>").
struct LibraryPlayAllButton: View {
    let videos: [VideoSummary]
    var queueName: String?
    var more: (() -> QueueSource?)?

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Button {
            guard let first = videos.first else { return }
            env.open(first, queue: Array(videos.dropFirst()), more: more?(), queueName: queueName)
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

extension AccountVideosModel {
    /// The rest of this list as the source of a play queue (`queueSource(fetch:filter:)`): the pages come from the
    /// signed-in account (`page` makes the call for the page behind a token), and the viewer's feed filters, as they are
    /// when each page arrives, are applied to them like to the list itself.
    ///
    /// The queue outlives the screen: it holds the environment weakly, and never the model or the view.
    func queueSource(
        using env: AppEnvironment,
        page: @escaping (any YouTubeAccountService, String) async throws -> Page<VideoSummary>
    ) -> QueueSource? {
        queueSource(
            fetch: { [weak env] token in
                guard let env else { return Page() }
                return try await env.viaAccount { try await page($0, token) }
            },
            filter: { [weak env] videos in env?.contentFilter.filter(videos) ?? videos }
        )
    }
}
