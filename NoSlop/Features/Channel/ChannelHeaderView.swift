import NoSlopKit
import SwiftUI

/// The top of a channel page: banner (about 6:1), avatar, name, handle, "subscribers · videos", the description
/// (3 lines, tap to expand) and the Subscribe button.
struct ChannelHeaderView: View {
    let header: ChannelHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let bannerURL = header.bannerURL {
                RemoteImage(url: bannerURL, contentMode: .fill)
                    .aspectRatio(Theme.bannerAspectRatio, contentMode: .fit)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 16) {
                ChannelAvatarView(url: header.avatarURL, size: 72)

                VStack(alignment: .leading, spacing: 3) {
                    Text(header.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let handle = header.handle, !handle.isEmpty {
                        Text(handle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let stats {
                        Text(stats)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.padding)

            if let description = header.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                ReadMoreText(text: description)
                    .padding(.horizontal, Theme.padding)
            }

            SubscribeButton(channel: header.ref)
                .padding(.horizontal, Theme.padding)
        }
        .padding(.bottom, Theme.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "1.25M subscribers · 1.5K videos"; whichever is known.
    private var stats: String? {
        let parts = [header.subscriberCountText, header.videoCountText].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#Preview {
    ScrollView {
        ChannelHeaderView(
            header: ChannelHeader(
                id: SampleData.blender.id,
                name: SampleData.blender.name,
                handle: SampleData.blender.handle,
                avatarURL: SampleData.blender.avatarURL,
                bannerURL: SampleData.channelBannerURL,
                subscriberCountText: SampleData.blender.subscriberCountText,
                videoCountText: SampleData.blender.videoCountText,
                description: SampleData.blender.descriptionSnippet
            )
        )
    }
    .environment(AppEnvironment.preview())
}
