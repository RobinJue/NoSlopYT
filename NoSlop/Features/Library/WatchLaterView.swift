import NoSlopKit
import SwiftUI

/// Videos saved for later. A row plays that video and queues the ones below it; swipe to remove; Edit to reorder.
struct WatchLaterView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let videos = env.library.watchLater

        Group {
            if videos.isEmpty {
                EmptyStateView(
                    title: "Nothing saved",
                    systemImage: "clock",
                    message: "Choose Save to Watch Later in a video's menu to find it here."
                )
            } else {
                List {
                    HStack {
                        LibraryPlayAllButton(videos: videos)
                        Spacer(minLength: 0)
                    }
                    .listRowSeparator(.hidden)

                    ForEach(videos) { video in
                        LibraryVideoRow(video: video) {
                            play(video, in: videos)
                        }
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                // The video is in the list, so toggling takes it out.
                                env.library.toggleWatchLater(video)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { source, destination in
                        env.library.moveWatchLater(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .miniPlayerClearance()
            }
        }
        .navigationTitle("Watch Later")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if videos.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
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
        WatchLaterView()
    }
    .environment(AppEnvironment.preview())
}
