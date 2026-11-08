import NoSlopKit
import SwiftUI

/// The minimized player: a 64 pt bar with a live (tiny) video surface, the title and channel, play/pause and close.
/// Tapping the bar, or swiping it up, expands the player again. The overlay container pins it above the tab bar.
struct MiniPlayerView: View {
    @Environment(AppEnvironment.self) private var env

    static let height: CGFloat = 64
    private static let cornerRadius: CGFloat = 16
    /// The title and the channel stop following the viewer's text size here. The bar is a fixed 64 pt (what
    /// `Theme.miniPlayerInset` and `MiniPlayerPlacement` are measured for), and two lines of accessibility-size text are
    /// taller than that: they would be cut off at the top and the bottom. Up to here they fit, and the expanded player
    /// shows the title at any size.
    private static let largestTextSize = DynamicTypeSize.xxxLarge

    var body: some View {
        let player = env.player

        HStack(spacing: 0) {
            Button {
                player.expand()
            } label: {
                HStack(spacing: 10) {
                    surface(player)
                    titles(player)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle(player))
            .accessibilityHint("Opens the player")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: playPauseIcon(player))
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            // A video YouTube will not hand out has nothing to press: play would only ask again.
            .disabled(player.failureMessage != nil && !player.failureIsWorthRetrying)
            .accessibilityLabel(transportLabel(player))

            Button {
                player.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close player")
        }
        .foregroundStyle(.primary)
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            progressLine(player)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .modifier(MiniPlayerBackground(cornerRadius: Self.cornerRadius))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    if value.translation.height < -24 {
                        player.expand()
                    }
                }
        )
    }

    // MARK: Pieces

    private func surface(_ player: PlayerController) -> some View {
        ZStack {
            Color.black
            if let video = player.currentVideo {
                RemoteImage(url: video.displayThumbnails.best(minWidth: 320)?.url, contentMode: .fill)
                    .opacity(player.showsPoster ? 1 : 0)
            }
            VideoSurfaceView(player: player.avPlayer, pictureInPicture: player.pictureInPicture)
                .opacity(player.isAudioOnlyPlayback ? 0 : 1)
            if player.state == .loading || player.state == .buffering {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else if player.failureMessage != nil {
                ZStack {
                    Color.black.opacity(0.6)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 85, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private func titles(_ player: PlayerController) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let video = player.currentVideo {
                VideoTitleText(video: video, lineLimit: 1)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if player.failureMessage != nil {
                    Text("Couldn\u{2019}t play")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let channel = video.channel?.name, !channel.isEmpty {
                    Text(channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dynamicTypeSize(...Self.largestTextSize)
    }

    private func progressLine(_ player: PlayerController) -> some View {
        GeometryReader { proxy in
            let fraction = progressFraction(player)
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.12))
                Rectangle().fill(Theme.accent).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 2)
        .opacity(player.duration > 0 && !player.isLive ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func progressFraction(_ player: PlayerController) -> CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(max(player.currentTime / player.duration, 0), 1))
    }

    private func transportLabel(_ player: PlayerController) -> String {
        if player.failureMessage != nil { return player.failureIsWorthRetrying ? "Retry" : "Couldn\u{2019}t play" }
        return player.isPlaybackActive ? "Pause" : (player.state == .ended ? "Replay" : "Play")
    }

    private func playPauseIcon(_ player: PlayerController) -> String {
        if player.failureMessage != nil {
            return player.failureIsWorthRetrying ? "arrow.clockwise" : "exclamationmark.triangle.fill"
        }
        if player.state == .ended { return "arrow.counterclockwise" }
        return player.isPlaybackActive ? "pause.fill" : "play.fill"
    }

    /// The bar's backdrop: the iOS 26 glass of the floating tab bar below it, a blurred material before that.
    private struct MiniPlayerBackground: ViewModifier {
        let cornerRadius: CGFloat

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if #available(iOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
    }

    private func accessibilityTitle(_ player: PlayerController) -> String {
        // The title the visible text shows: with De-clickbait titles on, the community title.
        guard let video = player.currentVideo, let shown = player.displayTitle else { return "Player" }
        let title = shown.isEmpty ? "Video" : shown
        if player.failureMessage != nil { return "\(title), couldn\u{2019}t play" }
        if let channel = video.channel?.name, !channel.isEmpty {
            return "\(title), \(channel)"
        }
        return title
    }
}
