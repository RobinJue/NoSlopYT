import SwiftUI

/// PLACEHOLDER (Task 1B). Task 8 owns this file and replaces it with the real screen; the type name and the
/// initializer are final.
struct ChannelView: View {
    let channelID: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.square")
                .font(.largeTitle)
            Text("Channel")
                .font(.title2.weight(.semibold))
            Text("Channel \(channelID)")
                .font(.footnote.monospaced())
                .multilineTextAlignment(.center)
            Text("Placeholder")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Channel")
        .navigationBarTitleDisplayMode(.inline)
    }
}
