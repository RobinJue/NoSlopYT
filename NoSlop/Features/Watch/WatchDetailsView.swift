import NoSlopKit
import SwiftUI

/// PLACEHOLDER (Task 1B). Task 9 owns this file and replaces it with the real watch page (title, channel row,
/// actions, description, chapters, comments, related videos); the type name and the initializer are final.
///
/// It is shown under the player inside the expanded overlay.
struct WatchDetailsView: View {
    let video: VideoSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(video.title.isEmpty ? "Untitled video" : video.title)
                    .font(.title3.weight(.semibold))
                if let channel = video.channel {
                    Text(channel.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Watch details for \(video.id)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                Text("Placeholder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.padding)
        }
    }
}
