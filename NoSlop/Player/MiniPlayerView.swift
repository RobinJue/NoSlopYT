import NoSlopKit
import SwiftUI

/// PLACEHOLDER (Task 1B). Task 10 owns this file and replaces it with the real mini player (live video surface,
/// title, channel, play/pause, close). The type name and the initializer are final.
struct MiniPlayerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let player = env.player
        HStack(spacing: Theme.padding) {
            Button {
                player.expand()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: player.currentVideo))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Mini player placeholder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")

            Button {
                player.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Close player")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func title(for video: VideoSummary?) -> String {
        guard let video else { return "" }
        return video.title.isEmpty ? video.id : video.title
    }
}
