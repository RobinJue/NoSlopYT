import SwiftUI

/// PLACEHOLDER (Task 1B). Task 9 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct DownloadsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.largeTitle)
            Text("Downloads")
                .font(.title2.weight(.semibold))
            Text("Placeholder")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}
