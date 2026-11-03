import AVKit
import NoSlopKit
import SwiftUI

/// Everything drawn over the video: tap to show or hide the controls, double-tap a half to jump 10 s, and the
/// controls themselves.
///
/// - Top: chevron (minimize, or leave full screen), title, AirPlay, captions on/off, settings menu.
/// - Centre: back 10 s, play/pause (a spinner while buffering), forward 10 s.
/// - Bottom: position / length, Picture in Picture, full screen, and the seek bar.
///
/// While the video plays the controls fade out after three seconds without a touch. Whenever it is not playing
/// (paused, ended, loading, failed) they stay.
struct PlayerControlsView: View {
    let isFullscreen: Bool

    @Environment(AppEnvironment.self) private var env

    @State private var isVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var isSettingsOpen = false
    @State private var ripple: Ripple?
    @State private var rippleTask: Task<Void, Never>?

    private enum Side {
        case leading, trailing
    }

    private struct Ripple: Equatable {
        var side: Side
        var seconds: Int
    }

    private static let jump = 10.0
    private static let autoHideDelay = 3.0

    var body: some View {
        let player = env.player
        let isRunning = player.state == .playing || player.state == .buffering
        let showsChrome = isVisible || !isRunning || isSettingsOpen

        ZStack {
            // While the player shows its error the area belongs to the buttons of the error view.
            gestureSurface(player)
                .allowsHitTesting(player.failureMessage == nil)

            if showsChrome {
                chrome(player)
                    .transition(.opacity)
            } else if isBusy(player) {
                // The controls are hidden: the spinner still has to say that nothing is playing right now.
                busyIndicator(player)
                    .transition(.opacity)
            }

            if let ripple {
                rippleView(ripple)
            }

            // Captions sit above the controls and their dimming, lifted clear of the seek bar while the controls are up.
            if let text = player.captionText {
                CaptionOverlayView(text: text, isLarge: isFullscreen, liftsAboveControls: showsChrome)
            }

            // "Skipped sponsor · Undo" sits in the top corner, below the title bar while that is showing, so it never
            // meets the captions or the controls at the bottom.
            if let notice = player.skipNotice {
                SkipNoticeView(notice: notice) { player.undoSkip() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 14)
                    .padding(.top, showsChrome ? 50 : 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        .animation(.spring(duration: 0.3), value: player.skipNotice)
        .onChange(of: player.state) { _, newState in
            switch newState {
            case .playing:
                scheduleHide()
            case .buffering:
                break
            default:
                hideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) { isVisible = true }
            }
        }
        .onChange(of: isFullscreen) { _, _ in
            show()
        }
        .task {
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            rippleTask?.cancel()
        }
    }

    // MARK: Gestures

    private func gestureSurface(_ player: PlayerController) -> some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    doubleTap(at: location.x, width: proxy.size.width, player: player)
                }
                .onTapGesture {
                    toggleChrome()
                }
        }
        .accessibilityElement()
        .accessibilityLabel("Video")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Back 10 seconds") { player.skip(by: -Self.jump) }
        .accessibilityAction(named: "Forward 10 seconds") { player.skip(by: Self.jump) }
        .accessibilityAction(named: player.isPlaybackActive ? "Pause" : "Play") { player.togglePlayPause() }
    }

    private func doubleTap(at x: CGFloat, width: CGFloat, player: PlayerController) {
        let side: Side = x < width / 2 ? .leading : .trailing
        player.skip(by: side == .leading ? -Self.jump : Self.jump)

        // Repeated double taps on the same side add up.
        let previous = ripple?.side == side ? (ripple?.seconds ?? 0) : 0
        withAnimation(.easeOut(duration: 0.15)) {
            ripple = Ripple(side: side, seconds: previous + Int(Self.jump))
        }
        rippleTask?.cancel()
        rippleTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { ripple = nil }
        }
    }

    private func rippleView(_ ripple: Ripple) -> some View {
        HStack(spacing: 0) {
            if ripple.side == .trailing {
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                Image(systemName: ripple.side == .leading ? "backward.fill" : "forward.fill")
                    .font(.title2)
                Text("\(ripple.seconds) seconds")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 48, style: .continuous))
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.45 }
            if ripple.side == .leading {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 12)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    // MARK: Visibility

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { isVisible.toggle() }
        if isVisible {
            scheduleHide()
        } else {
            hideTask?.cancel()
        }
    }

    /// Shows the controls and starts the fade-out countdown.
    private func show() {
        withAnimation(.easeInOut(duration: 0.2)) { isVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let player = env.player
        guard player.state == .playing || player.state == .buffering else { return }
        hideTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.autoHideDelay))
                guard !Task.isCancelled else { return }
                // Not while the viewer is dragging the seek bar or choosing in the settings popover.
                if isScrubbing || isSettingsOpen { continue }
                withAnimation(.easeOut(duration: 0.25)) { isVisible = false }
                return
            }
        }
    }

    // MARK: Controls

    private func chrome(_ player: PlayerController) -> some View {
        let failed = player.failureMessage != nil
        return ZStack {
            Color.black.opacity(failed ? 0 : 0.3)
                .allowsHitTesting(false)
            VStack {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                    .opacity(failed ? 0 : 1)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar(player, failed: failed)
                Spacer(minLength: 0)
                if !failed {
                    bottomBar(player)
                }
            }

            if !failed {
                centerCluster(player)
            }
        }
    }

    private func topBar(_ player: PlayerController, failed: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                if isFullscreen {
                    player.toggleFullscreen()
                } else {
                    player.minimize()
                }
            } label: {
                iconLabel("chevron.down", size: 20)
            }
            .accessibilityLabel(isFullscreen ? "Exit full screen" : "Minimize player")

            if let video = player.currentVideo {
                VideoTitleText(video: video, lineLimit: 1)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            } else {
                Spacer(minLength: 0)
            }

            if !failed {
                AirPlayButton()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("AirPlay")

                if !player.captionTracks.isEmpty {
                    Button {
                        player.toggleCaptions()
                        show()
                    } label: {
                        iconLabel(player.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill", size: 20)
                    }
                    .accessibilityLabel(player.selectedCaption == nil ? "Turn captions on" : "Turn captions off")
                }

                PlayerSettingsMenu { presented in
                    isSettingsOpen = presented
                    if presented {
                        hideTask?.cancel()
                    } else {
                        show()
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func centerCluster(_ player: PlayerController) -> some View {
        let spacing: CGFloat = isFullscreen ? 72 : 44
        return VStack(spacing: 8) {
            centerButtons(player, spacing: spacing)
            if player.isWaitingForConnection {
                Text("Waiting for connection…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private func centerButtons(_ player: PlayerController, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button {
                player.skip(by: -Self.jump)
                show()
            } label: {
                iconLabel("gobackward.10", size: 28)
            }
            .disabled(player.isLive)
            .opacity(player.isLive ? 0.3 : 1)
            .accessibilityLabel("Back 10 seconds")

            centerButton(player)

            Button {
                player.skip(by: Self.jump)
                show()
            } label: {
                iconLabel("goforward.10", size: 28)
            }
            .disabled(player.isLive)
            .opacity(player.isLive ? 0.3 : 1)
            .accessibilityLabel("Forward 10 seconds")
        }
    }

    /// The video is not playing although the viewer wants it to: loading, buffering, or waiting for the connection.
    private func isBusy(_ player: PlayerController) -> Bool {
        player.state == .buffering || (player.state == .loading && player.isPlaybackActive)
    }

    private func busyIndicator(_ player: PlayerController) -> some View {
        VStack(spacing: 6) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            if player.isWaitingForConnection {
                Text("Waiting for connection…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(14)
        .background(.black.opacity(player.isWaitingForConnection ? 0.55 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.isWaitingForConnection ? "Waiting for connection" : "Buffering")
    }

    @ViewBuilder
    private func centerButton(_ player: PlayerController) -> some View {
        if isBusy(player) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .frame(width: 64, height: 64)
                .accessibilityLabel(player.isWaitingForConnection ? "Waiting for connection" : "Buffering")
        } else {
            Button {
                player.togglePlayPause()
                show()
            } label: {
                Image(systemName: centerIcon(player))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.45), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel(player.state == .ended ? "Replay" : (player.isPlaybackActive ? "Pause" : "Play"))
        }
    }

    private func centerIcon(_ player: PlayerController) -> String {
        if player.state == .ended { return "arrow.counterclockwise" }
        return player.isPlaybackActive ? "pause.fill" : "play.fill"
    }

    private func bottomBar(_ player: PlayerController) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                timeLabel(player)
                Spacer(minLength: 0)
                if PictureInPictureController.isSupported {
                    Button {
                        player.togglePictureInPicture()
                        show()
                    } label: {
                        iconLabel(player.isPictureInPictureActive ? "pip.exit" : "pip.enter", size: 19)
                    }
                    .disabled(!player.isPictureInPicturePossible && !player.isPictureInPictureActive)
                    .opacity(player.isPictureInPicturePossible || player.isPictureInPictureActive ? 1 : 0.4)
                    .accessibilityLabel(player.isPictureInPictureActive ? "Stop Picture in Picture" : "Picture in Picture")
                }
                Button {
                    player.toggleFullscreen()
                } label: {
                    iconLabel(isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 18)
                }
                .accessibilityLabel(isFullscreen ? "Exit full screen" : "Full screen")
            }

            if player.isLive {
                Color.clear.frame(height: 10)
            } else {
                SeekBarView(
                    currentTime: player.currentTime,
                    duration: player.duration,
                    bufferedTime: player.bufferedTime,
                    segments: player.segments,
                    chapters: player.chapters,
                    onScrubbing: { scrubbing in
                        isScrubbing = scrubbing
                        if scrubbing {
                            hideTask?.cancel()
                        } else {
                            scheduleHide()
                        }
                    },
                    onSeek: { player.seek(to: $0) }
                )
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func timeLabel(_ player: PlayerController) -> some View {
        if player.isLive {
            Text("LIVE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Text("\(Self.clock(player.currentTime)) / \(player.duration > 0 ? Self.clock(player.duration) : "--:--")")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
    }

    private func iconLabel(_ systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return DurationFormatter.string(seconds: Int(max(0, seconds)))
    }
}

/// The system AirPlay route picker, tinted white for the dark video background.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = true
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
