import NoSlopKit
import SwiftUI

/// The video, playlist and channel rows the way the screens host them: in a stack inside a scroll view, each in a
/// button (the playlist screen, the search results, the Up next list). The previews in the row files use a `List`,
/// which fills its cells and aligns what is in them to the leading edge by itself, so they cannot show a row that is
/// narrower than its column. This is the check for that.
///
/// The tinted band is the part of the row that answers to a tap. At every text size it has to run from one padding to the
/// other, starting at the leading edge, under a video with a short title, a playlist with a short name and a channel
/// without a description: those are the rows that would be narrower than the column if they did not ask for its width.
private struct RowsInAStack: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                hosted { VideoRowView(video: SampleData.videos[4]) } // "Me at the zoo"
                hosted { PlaylistRowView(playlist: SampleData.blenderPlaylist) } // "Blender · Playlist"
                hosted { ChannelRowView(channel: SampleData.rickAstley) } // no description snippet
                hosted { VideoRowView(video: SampleData.videos[6]) } // a long title, for comparison
            }
        }
        .environment(AppEnvironment.preview())
    }

    private func hosted<Row: View>(@ViewBuilder _ row: () -> Row) -> some View {
        Button {} label: {
            row()
                .background(Theme.accent.opacity(0.15))
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, 6)
        }
        .buttonStyle(.pressableCard)
    }
}

#Preview("Rows in a stack") {
    RowsInAStack()
}

#Preview("Rows in a stack, accessibility text") {
    RowsInAStack()
        .dynamicTypeSize(.accessibility2)
}
