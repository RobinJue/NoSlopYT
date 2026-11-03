import SwiftUI

/// PLACEHOLDER (Task 1B). Task 10 owns this file and replaces it with the real overlay (drag-to-minimize panel,
/// mini player above the tab bar, fullscreen). The type name and the initializer are final.
///
/// `RootView` puts it in an `.overlay` over the whole `TabView`. Hidden, it draws nothing and lets touches through.
struct PlayerOverlayContainer: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let player = env.player
        ZStack {
            switch player.presentation {
            case .hidden:
                EmptyView()

            case .expanded:
                if let video = player.currentVideo {
                    VStack(spacing: 0) {
                        PlayerHostView()
                        WatchDetailsView(video: video)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground).ignoresSafeArea())
                    .transition(.move(edge: .bottom))
                }

            case .minimized:
                if player.currentVideo != nil {
                    VStack {
                        Spacer()
                        MiniPlayerView()
                            .padding(.horizontal, Theme.padding)
                            // Clear of the tab bar.
                            .padding(.bottom, 72)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.35), value: player.presentation)
    }
}
