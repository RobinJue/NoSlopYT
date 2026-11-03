import SwiftUI

/// PLACEHOLDER (Task 1B). Task 9 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct LocalPlaylistView: View {
    let playlistID: UUID

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
            Text("Playlist")
                .font(.title2.weight(.semibold))
            Text("Local playlist \(playlistID.uuidString)")
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
