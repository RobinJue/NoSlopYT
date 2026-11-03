import SwiftUI

/// PLACEHOLDER (Task 1B). Task 9 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct WatchLaterView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.largeTitle)
            Text("Watch Later")
                .font(.title2.weight(.semibold))
            Text("Placeholder")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Watch Later")
        .navigationBarTitleDisplayMode(.inline)
    }
}
