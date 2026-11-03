import NoSlopKit
import SwiftUI

/// A channel in a list or in search results: avatar, name, "@handle · subscribers", a short description and a
/// Subscribe button. Draws only; the screen decides what tapping the row does (usually `env.show(.channel(id:))`).
struct ChannelRowView: View {
    let channel: ChannelSummary

    var body: some View {
        HStack(spacing: 16) {
            ChannelAvatarView(url: channel.avatarURL, size: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let snippet = channel.descriptionSnippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)

            SubscribeButton(channel: channel.ref)
        }
        .contentShape(Rectangle())
    }

    /// "@handle · 1.2M subscribers"
    private var detail: String? {
        let parts = [channel.handle, channel.subscriberCountText].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
