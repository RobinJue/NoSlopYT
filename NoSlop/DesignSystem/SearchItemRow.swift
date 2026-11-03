import NoSlopKit
import SwiftUI

/// One result of a mixed list (search results, a channel's tabs): a video card, a channel row or a playlist row.
///
/// Unlike the cards and rows it draws, this one is the standard mixed-result row and also navigates: a video opens
/// in the player, a channel or playlist is shown on the current tab. Videos get the context menu.
struct SearchItemRow: View {
    let item: SearchItem

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch item {
        case .video(let video):
            Button {
                env.open(video)
            } label: {
                VideoCardView(video: video)
            }
            .buttonStyle(.plain)
            .videoContextMenu(video)

        case .channel(let channel):
            Button {
                env.show(.channel(id: channel.id))
            } label: {
                ChannelRowView(channel: channel)
                    .padding(.horizontal, Theme.padding)
            }
            .buttonStyle(.plain)

        case .playlist(let playlist):
            Button {
                env.show(.playlist(id: playlist.id))
            } label: {
                PlaylistRowView(playlist: playlist)
                    .padding(.horizontal, Theme.padding)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    ScrollView {
        LazyVStack(spacing: 20) {
            SearchItemRow(item: .video(SampleData.videos[0]))
            SearchItemRow(item: .channel(SampleData.blenderGuru))
            SearchItemRow(item: .playlist(SampleData.playlist))
        }
    }
    .environment(AppEnvironment.preview())
}
