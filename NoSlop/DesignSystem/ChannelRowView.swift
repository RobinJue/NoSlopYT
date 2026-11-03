import NoSlopKit
import SwiftUI

/// A channel in a list or in search results: avatar, name, "@handle" and the subscriber count on lines of their
/// own, a short description and a Subscribe button. Draws only; the screen decides what tapping the row does
/// (usually `env.show(.channel(id:))`).
struct ChannelRowView: View {
    let channel: ChannelSummary

    var body: some View {
        HStack(spacing: 16) {
            ChannelAvatarView(url: channel.avatarURL, size: 64)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(1)
                if let handle = nonEmpty(channel.handle) {
                    Text(handle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let stats = statsText {
                    Text(stats)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let snippet = nonEmpty(channel.descriptionSnippet) {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)

            SubscribeButton(channel: channel.ref)
        }
        .contentShape(Rectangle())
    }

    /// "1.25M subscribers", or the video count when the subscriber count is not known.
    private var statsText: String? {
        nonEmpty(channel.subscriberCountText) ?? nonEmpty(channel.videoCountText)
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

#Preview {
    List {
        ChannelRowView(channel: SampleData.blender)
        ChannelRowView(channel: SampleData.blenderGuru)
    }
    .listStyle(.plain)
    .environment(AppEnvironment.preview())
}
