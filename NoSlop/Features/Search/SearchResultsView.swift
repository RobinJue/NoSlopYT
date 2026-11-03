import SwiftUI

/// PLACEHOLDER (Task 1B). Task 8 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct SearchResultsView: View {
    let query: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
            Text("Search results")
                .font(.title2.weight(.semibold))
            Text("Search results for \(query)")
                .font(.footnote.monospaced())
                .multilineTextAlignment(.center)
            Text("Placeholder")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Search results")
        .navigationBarTitleDisplayMode(.inline)
    }
}
