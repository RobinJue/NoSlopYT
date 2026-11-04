import NoSlopKit
import SwiftUI

/// How the expanded player is laid out.
enum PlayerLayout {
    /// Full screen: the viewer asked for it, or an iPhone is held sideways (a 16:9 picture in a landscape phone is
    /// small enough already).
    static func isFullscreen(_ player: PlayerController, verticalSizeClass: UserInterfaceSizeClass?) -> Bool {
        player.isFullscreen || isLandscapePhone(verticalSizeClass: verticalSizeClass)
    }

    static func isLandscapePhone(verticalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
    }

    /// The tab bar is at the top only for an iPad in a regular-width window. An iPhone has it at the bottom (a Plus or
    /// Max held sideways is regular width too), and so does an iPad window of compact width: Slide Over, a narrow Split
    /// View, a narrowed window.
    static func tabBarIsAtTop(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        MiniPlayerPlacement.tabBarIsAtTop(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            isRegularWidth: horizontalSizeClass == .regular
        )
    }
}

/// The player itself: the video, its thumbnail until the first frame, captions, the controls, the "skipped sponsor"
/// toast, and the failure and Picture in Picture states. It fills the frame its parent gives it (the container makes
/// that 16:9, or the whole screen in full screen); in full screen the black background and the video reach under the
/// notch and the home indicator while the controls stay inside the safe area.
struct PlayerHostView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let player = env.player
        let fullscreen = PlayerLayout.isFullscreen(player, verticalSizeClass: verticalSizeClass)
        let bleed: Edge.Set = fullscreen ? .all : []

        ZStack {
            Color.black
                .ignoresSafeArea(edges: bleed)

            if let video = player.currentVideo {
                RemoteImage(url: posterURL(for: video), contentMode: .fill)
                    .ignoresSafeArea(edges: bleed)
                    .opacity(player.showsPoster ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: player.showsPoster)
                    .allowsHitTesting(false)
            }

            VideoSurfaceView(player: player.avPlayer, pictureInPicture: player.pictureInPicture)
                .ignoresSafeArea(edges: bleed)
                .opacity(player.isAudioOnlyPlayback ? 0 : 1)

            if player.isPictureInPictureActive {
                PictureInPicturePlaceholder()
            }

            // Below the controls, so the chevron (and the controls generally) stay usable on the error screen.
            if let message = player.failureMessage {
                PlayerFailureView(message: message, video: player.currentVideo, retry: { player.retry() })
            }

            PlayerControlsView(isFullscreen: fullscreen)
        }
        .clipped()
        .accessibilityElement(children: .contain)
    }

    /// A true 16:9 picture where there is one; the 4:3 renditions carry black bars that `.fill` crops away anyway.
    private func posterURL(for video: VideoSummary) -> URL? {
        video.displayThumbnails.best(minWidth: 640)?.url
    }
}

/// What the player area shows when the video cannot be played: the reason, Retry, and the way out to YouTube.
private struct PlayerFailureView: View {
    let message: String
    let video: VideoSummary?
    let retry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                    if let video {
                        Button("Open on YouTube") { openURL(video.watchURL) }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
    }
}

/// While Picture in Picture shows the video, the in-app surface is empty; say where it went. The controls stay on top
/// (their Picture in Picture button brings the video back).
private struct PictureInPicturePlaceholder: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "pip")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Playing in Picture in Picture")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
