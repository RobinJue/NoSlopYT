import NoSlopKit
import SwiftUI

/// A playlist in a list or in search results: a 160 pt-wide thumbnail with the video count on it, then title and
/// "Channel · Playlist". Draws only; the screen decides what a tap does (usually `env.show(.playlist(id:))`).
///
/// At accessibility text sizes the row is a stack, like `VideoRowView`: the thumbnail, then the text in the whole
/// width, without a line limit.
struct PlaylistRowView: View {
    let playlist: PlaylistSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.padding))

        layout {
            RemoteImage(url: playlist.thumbnails.best(minWidth: 320)?.url, contentMode: .fill)
                .aspectRatio(Theme.thumbnailAspectRatio, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { countBadge }
                .frame(width: Theme.rowThumbnailWidth)
                .clipShape(RoundedRectangle(cornerRadius: Theme.thumbnailCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(stacked ? nil : 2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(stacked ? nil : 2)
            }
            if !stacked {
                Spacer(minLength: 0)
            }
        }
        // The whole width, from the leading edge, stacked or not (see `VideoRowView`).
        .frame(maxWidth: .infinity, alignment: .leading)
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
                // The badge sits on a thumbnail of fixed width: at accessibility sizes it would grow wider than the
                // picture and end in "17...". It stays at the largest standard size; the count is also in the
                // accessibility label.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .lineLimit(1)
                .fixedSize()
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

#Preview("Accessibility text") {
    List {
        PlaylistRowView(playlist: SampleData.playlist)
        PlaylistRowView(playlist: SampleData.blenderPlaylist)
    }
    .listStyle(.plain)
    .dynamicTypeSize(.accessibility2)
    .environment(AppEnvironment.preview())
}
