import SwiftUI

/// PLACEHOLDER (Task 1B). Task 10 owns this file and replaces it with the real 16:9 player: the video surface plus
/// its controls. The type name and the initializer are final.
struct PlayerHostView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let player = env.player
        ZStack {
            Color.black
            VideoSurfaceView(player: player.avPlayer)
            VStack(spacing: 6) {
                Image(systemName: "play.rectangle")
                    .font(.largeTitle)
                Text("Player placeholder")
                    .font(.headline)
                Text(player.currentVideo?.id ?? "")
                    .font(.footnote.monospaced())
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            Button {
                player.minimize()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .accessibilityLabel("Minimize player")
        }
        .overlay(alignment: .topTrailing) {
            Button {
                player.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .accessibilityLabel("Close player")
        }
    }
}
