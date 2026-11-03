import SwiftUI

/// PLACEHOLDER (Task 1B). Task 9 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct SubscriptionsManagerView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.largeTitle)
            Text("Subscriptions")
                .font(.title2.weight(.semibold))
            Text("Placeholder")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
