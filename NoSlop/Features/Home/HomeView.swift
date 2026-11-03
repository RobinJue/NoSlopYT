import SwiftUI

/// PLACEHOLDER (Task 1B). Task 8 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct HomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house")
                .font(.largeTitle)
            Text("Home")
                .font(.title2.weight(.semibold))
            Text("Placeholder")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
    }
}
