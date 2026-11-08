import NoSlopKit
import SwiftUI

/// One result of a mixed list (search results, a channel's tabs): a video card, a channel row or a playlist row.
///
/// Unlike the cards and rows it draws, this one is the standard mixed-result row and also navigates: a video opens
/// in the player, a channel or playlist is shown on the current tab. Videos get the context menu.
struct SearchItemRow: View {
    let item: SearchItem
    /// Show a video as a full-width list row instead of a card, for a lone video between full-width rows in a grid.
    var videoAsRow = false

    @Environment(AppEnvironment.self) private var env
    @Environment(\.videoCardLayout) private var layout

    var body: some View {
        switch item {
        case .video(let video):
            Button {
                env.open(video)
            } label: {
                if videoAsRow {
                    VideoRowView(video: video)
                        .padding(.horizontal, inset)
                        .padding(.vertical, 4)
                        .accessibilityActions {
                            if let channel = video.channel {
                                Button("Open channel \(channel.name)") {
                                    env.show(.channel(id: channel.id))
                                }
                            }
                        }
                } else {
                    VideoCardView(video: video)
                }
            }
            .buttonStyle(.pressableCard)
            .videoContextMenu(video)

        case .channel(let channel):
            Button {
                env.show(.channel(id: channel.id))
            } label: {
                ChannelRowView(channel: channel)
                    .padding(.horizontal, inset)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.pressableCard)

        case .playlist(let playlist):
            Button {
                env.show(.playlist(id: playlist.id))
            } label: {
                PlaylistRowView(playlist: playlist)
                    .padding(.horizontal, inset)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.pressableCard)
        }
    }

    /// Rows are inset by the standard padding in a single column; in a multi-column grid the grid insets them.
    private var inset: CGFloat {
        layout == .inset ? 0 : Theme.padding
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
