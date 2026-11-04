import NoSlopKit
import SwiftUI

/// A compact row: a 160 pt-wide thumbnail on the left; on the right the title (2 lines), the channel name and
/// "views · age", each on its own line so nothing wraps in the middle of a phrase.
///
/// Like `VideoCardView` it only draws; the screen wraps it in a button and adds `.videoContextMenu(video)`.
/// It has no horizontal padding of its own, so it sits correctly inside a `List` or a padded stack.
///
/// At accessibility text sizes the thumbnail would leave the text about 190 pt, so the row is a stack: the thumbnail,
/// then the text in the whole width, without a line limit.
struct VideoRowView: View {
    let video: VideoSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.padding))

        layout {
            ThumbnailView(video: video)
                .frame(width: Theme.rowThumbnailWidth)
                .clipShape(RoundedRectangle(cornerRadius: Theme.thumbnailCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                VideoTitleText(video: video, lineLimit: stacked ? nil : 2)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.bottom, 1)

                if let name = video.channel?.name, !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(stacked ? nil : 1)
                }
                if let stats = Formatting.statsLine(for: video) {
                    Text(stats)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(stacked ? nil : 1)
                }
            }
            if !stacked {
                Spacer(minLength: 0)
            }
        }
        // At accessibility sizes the stack has no Spacer, so it is only as wide as its widest part, and a `LazyVStack` or
        // a grid cell centres a child that is narrower than its column: the row would be drawn off to the middle and
        // would take a tap only there. The frame gives the row the whole width, from its leading edge, and the tap area
        // with it (a content shape is the bounds of what it is put on).
        .frame(maxWidth: .infinity, alignment: .leading)
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

#Preview("Accessibility text") {
    List(SampleData.videos.prefix(4)) { video in
        VideoRowView(video: video)
    }
    .listStyle(.plain)
    .dynamicTypeSize(.accessibility2)
    .environment(AppEnvironment.preview())
}
