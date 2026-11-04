import NoSlopKit
import SwiftUI

/// A channel in a list or in search results: avatar, name, "@handle" and the subscriber count on lines of their
/// own, a short description and a Subscribe button. Draws only; the screen decides what tapping the row does
/// (usually `env.show(.channel(id:))`).
///
/// At accessibility text sizes the avatar, the text and the button no longer fit on one line (the button alone is
/// about 160 pt wide, and the name is left a few characters), so they are stacked, with the text in full.
struct ChannelRowView: View {
    let channel: ChannelSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 16))

        layout {
            ChannelAvatarView(url: channel.avatarURL, size: 64)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(stacked ? nil : 1)
                if let handle = nonEmpty(channel.handle) {
                    Text(handle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(stacked ? nil : 1)
                }
                if let stats = statsText {
                    Text(stats)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(stacked ? nil : 1)
                }
                if let snippet = nonEmpty(channel.descriptionSnippet) {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(stacked ? 4 : 2)
                        .padding(.top, 2)
                }
            }
            if !stacked {
                Spacer(minLength: 0)
            }

            // The button keeps its width, so that "Subscribe" never breaks in the middle of the word; a long name is
            // what gets cut.
            SubscribeButton(channel: channel.ref)
                .fixedSize(horizontal: true, vertical: false)
        }
        // The whole width, from the leading edge, stacked or not (see `VideoRowView`).
        .frame(maxWidth: .infinity, alignment: .leading)
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

#Preview("Accessibility text") {
    List {
        ChannelRowView(channel: SampleData.blender)
        ChannelRowView(channel: SampleData.blenderGuru)
    }
    .listStyle(.plain)
    .dynamicTypeSize(.accessibility2)
    .environment(AppEnvironment.preview())
}
