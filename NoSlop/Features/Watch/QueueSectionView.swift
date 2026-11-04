import NoSlopKit
import SwiftUI

/// "Playing from <name>": under a video that plays from a queue ("Play all" on a playlist, a tap on a row of a list), where
/// the queue came from, where in it the video is ("3 of 14", "3 of 100+" while more pages may come) and the next few
/// videos of it. A tap on one of them jumps to it and keeps the rest of the queue behind it.
///
/// It reads the queue from the player in a body of its own, so the watch page is not drawn again whenever the queue moves.
/// Nothing shows while no queue plays.
struct QueueSectionView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let outline = env.player.queueOutline {
            VStack(alignment: .leading, spacing: 0) {
                header(outline)
                    .padding(.bottom, 6)

                // Offsets, not video ids: a playlist may hold the same video twice.
                ForEach(Array(outline.upcoming.enumerated()), id: \.offset) { index, video in
                    Button {
                        env.player.playQueued(at: index, expecting: video.id)
                    } label: {
                        VideoRowView(video: video)
                    }
                    .buttonStyle(.plain)
                    .videoContextMenu(video)
                    .padding(.vertical, 6)
                    .accessibilityHint("Skips ahead in the queue to this video")
                }
            }
            .padding(.horizontal, Theme.padding)
            .padding(.top, 22)
        }
    }

    /// The title and the position. At accessibility text sizes they are stacked: a long name and the position do not share
    /// a line without one of them being cut.
    @ViewBuilder
    private func header(_ outline: QueueOutline) -> some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))

        layout {
            Text(outline.title)
                .font(.headline)
                .lineLimit(isLarge ? nil : 2)
                .multilineTextAlignment(.leading)
            if !isLarge {
                Spacer(minLength: 8)
            }
            Text(outline.positionText)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        // One element for VoiceOver, with the position said in words.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(outline.title), \(outline.spokenPositionText)")
        .accessibilityAddTraits(.isHeader)
    }
}
