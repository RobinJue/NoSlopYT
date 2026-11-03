import NoSlopKit
import SwiftUI

/// A compact row: a 160 pt-wide thumbnail on the left, title and "Channel · views · age" on the right.
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

            VStack(alignment: .leading, spacing: 4) {
                VideoTitleText(video: video, lineLimit: 2)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(Formatting.subtitle(for: video))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
