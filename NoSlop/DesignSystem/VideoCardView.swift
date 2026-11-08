import NoSlopKit
import SwiftUI

/// A feed card: a full-width 16:9 thumbnail, then channel avatar, title (2 lines) and "Channel · views · age".
///
/// The card only draws; what a tap on it does is up to the screen (usually `env.open(video)`), and so are the
/// context menu (`.videoContextMenu(video)`) and the playlist queue. The one exception is the avatar: it opens the
/// channel, as in the YouTube app (VoiceOver gets the same as a custom action on the card).
///
/// In a `FeedGrid` with several columns the card is inset and its thumbnail rounded (`videoCardLayout`); alone, or
/// in a single column, the thumbnail runs edge to edge and only the text is inset.
struct VideoCardView: View {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env
    @Environment(\.videoCardLayout) private var layout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility text sizes the title may take 4 lines and the subtitle wraps: the channel on its own line,
        // then views and age, as in `VideoRowView`. A card is as tall as its text, so cards in a grid row line up
        // at the top and never overlap.
        let large = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 10) {
            ThumbnailView(video: video)
                .clipShape(RoundedRectangle(cornerRadius: layout == .inset ? Theme.cornerRadius : 0, style: .continuous))

            HStack(alignment: .top, spacing: Theme.padding) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    VideoTitleText(video: video, lineLimit: large ? 4 : 2)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if large {
                        if let name = video.channel?.name, !name.isEmpty {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let stats = Formatting.statsLine(for: video) {
                            Text(stats)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(Formatting.subtitle(for: video))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, layout == .inset ? 0 : Theme.padding)
        }
        .contentShape(Rectangle())
        .accessibilityActions {
            if let channel = video.channel {
                Button("Open channel \(channel.name)") {
                    env.show(.channel(id: channel.id))
                }
            }
        }
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
            // Reached by VoiceOver through the card's "Open channel" action instead, so the card reads as one element.
            .accessibilityHidden(true)
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
