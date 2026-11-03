import NoSlopKit
import SwiftUI

/// The top of a playlist page: thumbnail, title, owner, "N videos", the description and "Play all".
struct PlaylistHeaderView: View {
    let info: PlaylistSummary
    let details: String?
    /// The first video, whose thumbnail stands in when the playlist has none.
    let firstVideo: VideoSummary?
    let playAll: () -> Void

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteImage(url: thumbnailURL, contentMode: .fill)
                .aspectRatio(Theme.thumbnailAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .accessibilityHidden(true)

            Text(info.title)
                .font(.title2.weight(.bold))
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)

            if let channel = info.channel {
                Button {
                    env.show(.channel(id: channel.id))
                } label: {
                    HStack(spacing: 8) {
                        ChannelAvatarView(url: channel.avatarURL, size: 24)
                        Text(channel.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.pressableCard)
                .accessibilityLabel("Open channel \(channel.name)")
            }

            if let countText {
                Text(countText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let details = details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
                ReadMoreText(text: details)
            }

            Button(action: playAll) {
                Label("Play all", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(firstVideo == nil)
        }
        .padding(.horizontal, Theme.padding)
        .padding(.bottom, Theme.padding)
        // A 16:9 picture at the width of an iPad would fill the screen.
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thumbnailURL: URL? {
        info.thumbnails.best(minWidth: 640)?.url ?? firstVideo?.displayThumbnails.best(minWidth: 640)?.url
    }

    /// "14 videos": YouTube's text when present, else the count.
    private var countText: String? {
        if let text = info.videoCountText, !text.isEmpty { return text }
        return info.videoCount.map(Formatting.videoCountText)
    }
}

#Preview {
    PlaylistHeaderView(
        info: SampleData.playlist,
        details: "A sample playlist.",
        firstVideo: SampleData.playlistVideos.first,
        playAll: {}
    )
    .environment(AppEnvironment.preview())
}
