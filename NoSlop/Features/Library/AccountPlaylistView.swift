import NoSlopKit
import SwiftUI

/// PLACEHOLDER (Task 1B). Task 9 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct AccountPlaylistView: View {
    let playlist: PlaylistSummary

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.largeTitle)
            Text("Playlist")
                .font(.title2.weight(.semibold))
            Text("YouTube playlist \(playlist.title) (\(playlist.id))")
                .font(.footnote.monospaced())
                .multilineTextAlignment(.center)
            Text("Placeholder")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.inline)
    }
}
