import SwiftUI

/// PLACEHOLDER (Task 1B). Task 9 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct AccountPlaylistsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.largeTitle)
            Text("Your YouTube playlists")
                .font(.title2.weight(.semibold))
            Text("Placeholder")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Your YouTube playlists")
        .navigationBarTitleDisplayMode(.inline)
    }
}
