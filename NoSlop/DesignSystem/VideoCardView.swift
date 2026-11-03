import NoSlopKit
import SwiftUI

/// A feed card: a full-width 16:9 thumbnail, then channel avatar, title (2 lines) and "Channel · views · age".
///
/// The card only draws; what a tap on it does is up to the screen (usually `env.open(video)`), and so are the
/// context menu (`.videoContextMenu(video)`) and the playlist queue. The one exception is the avatar: it opens the
/// channel, as in the YouTube app.
struct VideoCardView: View {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThumbnailView(video: video)

            HStack(alignment: .top, spacing: Theme.padding) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    VideoTitleText(video: video, lineLimit: 2)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(Formatting.subtitle(for: video))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.padding)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let channel = video.channel {
            Button {
                env.show(.channel(id: channel.id))
            } label: {
                ChannelAvatarView(url: channel.avatarURL, size: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open channel \(channel.name)")
        } else {
            ChannelAvatarView(url: nil, size: 36)
        }
    }
}

#Preview {
    ScrollView {
        LazyVStack(spacing: 20) {
            ForEach(SampleData.videos.prefix(3)) { video in
                VideoCardView(video: video)
            }
        }
    }
    .environment(AppEnvironment.preview())
}
