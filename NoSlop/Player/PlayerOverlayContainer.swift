import NoSlopKit
import SwiftUI

/// The player's place in the app, drawn over the whole `TabView` by `RootView`.
///
/// - Hidden: nothing, and touches go through.
/// - Expanded: a full-screen panel over the tabs with the 16:9 player at the top (below the status bar) and the
///   watch details scrolling underneath. Dragging the player down by more than 120 pt, or the chevron, minimizes it.
///   For VoiceOver the panel is a screen of its own: modal, with the tabs behind it hidden (`RootView`), and the
///   two-finger scrub (escape) does what the chevron does.
/// - Minimized: the mini player bar above the tab bar. Tapping it expands the panel again.
/// - Full screen (the viewer asked, or an iPhone is held sideways): only the player, edge to edge on black, with the
///   status bar and home indicator out of the way. The watch details stay in the panel, without any height, so that
///   they are where the viewer left them when full screen ends.
struct PlayerOverlayContainer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// How far the expanded panel follows the finger while it is dragged down.
    @State private var dragOffset: CGFloat = 0

    private static let minimizeDistance: CGFloat = 120
    /// On a wide screen the player and the details share one centred column instead of a 1000 pt wide video. An iPad
    /// in portrait (834 pt and up) still gets the full width.
    private static let columnLimit: CGFloat = 900
    /// The floating tab bar is inset 21 pt from the screen edges; the mini player lines up with it.
    private static let miniPlayerInset: CGFloat = 20

    var body: some View {
        let player = env.player

        ZStack {
            switch player.presentation {
            case .hidden:
                EmptyView()

            case .expanded:
                if let video = player.currentVideo {
                    expandedPanel(player, video: video)
                        .transition(.move(edge: .bottom))
                }

            case .minimized:
                if player.currentVideo != nil {
                    minimizedBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.38, bounce: 0.1), value: player.presentation)
        .onChange(of: PlayerLayout.isLandscapePhone(verticalSizeClass: verticalSizeClass)) { _, landscape in
            // Turning an iPhone sideways enters full screen, turning it back leaves it.
            if player.presentation == .expanded {
                player.isFullscreen = landscape
            }
        }
        .onChange(of: player.presentation) { _, presentation in
            guard presentation == .expanded else { return }
            dragOffset = 0
            if PlayerLayout.isLandscapePhone(verticalSizeClass: verticalSizeClass) {
                player.isFullscreen = true
            }
        }
        .onChange(of: env.settings.deArrowTitles) { _, _ in
            // The lock screen and the spoken label of the mini player show the title the setting picks.
            player.deArrowSettingChanged()
        }
    }

    // MARK: Expanded

    private func expandedPanel(_ player: PlayerController, video: VideoSummary) -> some View {
        let fullscreen = PlayerLayout.isFullscreen(player, verticalSizeClass: verticalSizeClass)

        return GeometryReader { proxy in
            let columnWidth = fullscreen ? proxy.size.width : min(proxy.size.width, Self.columnLimit)
            let playerHeight = fullscreen ? proxy.size.height : columnWidth * 9.0 / 16.0

            VStack(spacing: 0) {
                PlayerHostView()
                    .frame(width: columnWidth, height: playerHeight)
                    .gesture(minimizeGesture(player), including: fullscreen ? .subviews : .all)

                // Full screen only collapses the page: it stays in the view tree, without any height, so that turning
                // the phone or tapping Full screen does not throw away the expanded title and description and an
                // open Comments sheet (they live in the page's own state), nor how far the viewer had scrolled (the
                // page puts its offset back itself when it has room again). The player is as tall as the panel then,
                // so the two still add up to the whole of it.
                WatchDetailsView(video: video)
                    .id(video.id)
                    .frame(width: columnWidth, height: fullscreen ? 0 : nil)
                    .clipped()
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)
                    .accessibilityHidden(fullscreen)
                    .ignoresSafeArea(edges: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background {
            (fullscreen ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()
        }
        .offset(y: dragOffset)
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        // For VoiceOver the panel is a screen of its own: it is modal (the tabs and the lists behind it, hidden by
        // `RootView` as well, are not part of it), VoiceOver is moved into it when it appears, and the two-finger
        // scrub (escape) leaves it the way the chevron does: full screen first, then the panel.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) {
            if fullscreen {
                player.toggleFullscreen()
            } else {
                player.minimize()
            }
        }
        .onAppear {
            AccessibilityNotification.ScreenChanged().post()
        }
    }

    /// Drag the player down to minimize it. The panel follows the finger, then either flies down or springs back.
    /// The drag is measured in the screen's coordinate space: the view that carries the gesture moves with the finger,
    /// so its own (local) coordinates would shrink the translation while dragging.
    private func minimizeGesture(_ player: PlayerController) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let shouldMinimize = value.translation.height > Self.minimizeDistance
                    || value.predictedEndTranslation.height > Self.minimizeDistance * 3
                if shouldMinimize {
                    player.minimize()
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    // MARK: Minimized

    private var minimizedBar: some View {
        // With the tab bar at the top (an iPad in a regular-width window) the bar sits near the bottom edge; otherwise
        // (an iPhone, also held sideways, and an iPad window of compact width) it clears the tab bar at the bottom.
        let tabBarIsAtTop = PlayerLayout.tabBarIsAtTop(horizontalSizeClass: horizontalSizeClass)
        let clearance = MiniPlayerPlacement.bottomClearance(tabBarIsAtTop: tabBarIsAtTop)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            MiniPlayerView()
                .frame(maxWidth: horizontalSizeClass == .regular ? 560 : .infinity)
                .padding(.horizontal, Self.miniPlayerInset)
                .padding(.bottom, clearance)
        }
        .frame(maxWidth: .infinity)
    }
}
