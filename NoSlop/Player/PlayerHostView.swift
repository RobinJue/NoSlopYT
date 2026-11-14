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

            // The whole picture, with black bars where it does not fit, unless the viewer chose to fill the player for
            // this video (which crops the picture).
            VideoSurfaceView(
                player: player.avPlayer,
                pictureInPicture: player.pictureInPicture,
                videoGravity: player.fillsScreen ? .resizeAspectFill : .resizeAspect
            )
                .ignoresSafeArea(edges: bleed)
                .opacity(player.isAudioOnlyPlayback ? 0 : 1)

            if player.isPictureInPictureActive {
                PictureInPicturePlaceholder()
            }

            // Below the controls, so the chevron (and the controls generally) stay usable on the error screen.
            if let message = player.failureMessage {
                PlayerFailureView(
                    message: message,
                    video: player.currentVideo,
                    canRetry: player.failureIsWorthRetrying,
                    canPlayNext: player.canPlayNext,
                    isSkipping: player.isSkippingFailedVideo,
                    retry: { player.retry() },
                    playNext: { player.playNext() }
                )
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

/// What the player area shows when the video cannot be played: the reason, Retry (only when asking again could end
/// differently: not for a video YouTube will not hand out, `PlayerFailureAdvice`), Next video (when there is one, as on
/// the lock screen) and the way out to YouTube. The top
/// bar with the chevron that minimizes the player stays above it either way.
///
/// The area is the 16:9 frame of the player, which does not grow with the text. So the text follows the viewer's text
/// size only as far as the player controls do, and the content makes room as the reason gets longer: first it sits
/// below the top bar (whose chevron stays usable), then the warning icon goes, and then the reason scrolls. Retry and
/// Open on YouTube are never pushed out of the frame.
private struct PlayerFailureView: View {
    let message: String
    let video: VideoSummary?
    let canRetry: Bool
    let canPlayNext: Bool
    /// The player is about to go on to the next video by itself.
    let isSkipping: Bool
    let retry: () -> Void
    let playNext: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            ViewThatFits(in: .vertical) {
                // The usual look, in the middle of the frame (clear of the top bar and, to stay centred, of the bottom).
                VStack(spacing: 10) {
                    icon
                    reason
                    buttons
                }
                .padding(.vertical, ControlsFootprint.topBarHeight)

                VStack(spacing: 10) {
                    reason
                    buttons
                }
                .padding(.top, ControlsFootprint.topBarHeight)

                VStack(spacing: 10) {
                    ScrollView { reason }
                        .scrollBounceBehavior(.basedOnSize)
                    buttons
                }
                .padding(.top, ControlsFootprint.topBarHeight)
                .padding(.bottom, 8)
                .frame(maxHeight: .infinity)
            }
            .dynamicTypeSize(...PlayerControlsView.largestTextSize)
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.title2)
            .foregroundStyle(.white.opacity(0.9))
    }

    private var reason: some View {
        VStack(spacing: 4) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white)
            if isSkipping {
                Text("Going on to the next video\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
    }

    /// In a row when it fits the width, stacked when it does not (three buttons at a large text size on a narrow phone).
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttonItems }
            VStack(spacing: 8) { buttonItems }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var buttonItems: some View {
        if canRetry {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        if canPlayNext {
            Button("Next video", action: playNext)
                .buttonStyle(.bordered)
                .tint(.white)
        }
        if let video {
            Button("Open on YouTube") { openURL(video.watchURL) }
                .buttonStyle(.bordered)
                .tint(.white)
        }
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
