import NoSlopKit
import SwiftUI

/// A compact row: a 160 pt-wide thumbnail on the left; on the right the title (2 lines), the channel name and
/// "views · age", each on its own line so nothing wraps in the middle of a phrase.
///
/// Like `VideoCardView` it only draws; the screen wraps it in a button and adds `.videoContextMenu(video)`.
/// It has no horizontal padding of its own, so it sits correctly inside a `List` or a padded stack.
struct VideoRowView: View {
    let video: VideoSummary

    var body: some View {
        HStack(alignment: .top, spacing: Theme.padding) {
            ThumbnailView(video: video)
                .frame(width: Theme.rowThumbnailWidth)
                .clipShape(RoundedRectangle(cornerRadius: Theme.thumbnailCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                VideoTitleText(video: video, lineLimit: 2)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, 1)

                if let name = video.channel?.name, !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let stats = Formatting.statsLine(for: video) {
                    Text(stats)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    List(SampleData.videos.prefix(4)) { video in
        VideoRowView(video: video)
    }
    .listStyle(.plain)
    .environment(AppEnvironment.preview())
}
