import NoSlopKit
import SwiftUI

/// A playlist in a list or in search results: a 160 pt-wide thumbnail with the video count on it, then title and
/// "Channel · Playlist". Draws only; the screen decides what a tap does (usually `env.show(.playlist(id:))`).
struct PlaylistRowView: View {
    let playlist: PlaylistSummary

    var body: some View {
        HStack(alignment: .top, spacing: Theme.padding) {
            RemoteImage(url: playlist.thumbnails.best(minWidth: 320)?.url, contentMode: .fill)
                .aspectRatio(Theme.thumbnailAspectRatio, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { countBadge }
                .frame(width: Theme.rowThumbnailWidth)
                .clipShape(RoundedRectangle(cornerRadius: Theme.thumbnailCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// "14 videos"
    private var countText: String? {
        if let text = playlist.videoCountText, !text.isEmpty { return text }
        guard let count = playlist.videoCount else { return nil }
        return count == 1 ? "1 video" : "\(count) videos"
    }

    private var subtitle: String {
        [playlist.channel?.name, "Playlist"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var countBadge: some View {
        if let countText {
            Label(countText, systemImage: "list.bullet")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.badgeBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(6)
        }
    }
}

#Preview {
    List {
        PlaylistRowView(playlist: SampleData.playlist)
        PlaylistRowView(playlist: SampleData.blenderPlaylist)
    }
    .listStyle(.plain)
    .environment(AppEnvironment.preview())
}
