import NoSlopKit
import SwiftUI

/// The player's place in the app, drawn over the whole `TabView` by `RootView`.
///
/// - Hidden: nothing, and touches go through.
/// - Expanded: a full-screen panel over the tabs with the 16:9 player at the top (below the status bar) and the
///   watch details scrolling underneath. Dragging the player down by more than 120 pt, or the chevron, minimizes it.
/// - Minimized: the mini player bar above the tab bar. Tapping it expands the panel again.
/// - Full screen (the viewer asked, or an iPhone is held sideways): only the player, edge to edge on black, with the
///   status bar and home indicator out of the way.
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
    /// Distance from the bottom safe area to the bottom of the mini player: the iOS 26 floating tab bar rises about 48 pt
    /// above the safe area, and the mini player floats 10 pt above that.
    private static let tabBarClearance: CGFloat = 58
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

                if !fullscreen {
                    WatchDetailsView(video: video)
                        .id(video.id)
                        .frame(width: columnWidth)
                        .ignoresSafeArea(edges: .bottom)
                }
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
        // On iPad the tab bar is at the top, so the bar sits near the bottom edge; on iPhone it clears the tab bar.
        let clearance = UIDevice.current.userInterfaceIdiom == .pad ? 8 : Self.tabBarClearance

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
