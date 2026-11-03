import NoSlopKit
import SwiftUI

/// A round channel avatar. Without a URL (or while loading) it shows a neutral circle with a person glyph.
struct ChannelAvatarView: View {
    let url: URL?
    let size: CGFloat

    init(url: URL?, size: CGFloat = 36) {
        self.url = url
        self.size = size
    }

    var body: some View {
        RemoteImage(url: url, contentMode: .fill)
            .overlay {
                if url == nil {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack {
        ChannelAvatarView(url: SampleData.blender.avatarURL, size: 48)
        ChannelAvatarView(url: nil, size: 48)
    }
    .environment(AppEnvironment.preview())
    .padding()
}
