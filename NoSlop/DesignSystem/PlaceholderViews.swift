import NoSlopKit
import SwiftUI

// Loading placeholders ("skeletons"): grey shapes with the outline of the card, row or header that is about to
// appear, with a soft shimmer. They never touch the network and they are one VoiceOver element ("Loading").

extension View {
    /// A light band that sweeps across the view. With Reduce Motion on, the view just stays grey.
    func placeholderShimmer() -> some View {
        modifier(PlaceholderShimmer())
    }
}

private struct PlaceholderShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSweeping = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let band = proxy.size.width * 0.55
                        LinearGradient(
                            colors: [.clear, .white.opacity(colorScheme == .dark ? 0.14 : 0.55), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: isSweeping ? proxy.size.width : -band)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    isSweeping = true
                }
            }
    }
}

/// A grey bar standing in for a line of text.
private struct PlaceholderBar: View {
    var width: CGFloat?
    var height: CGFloat = 13

    var body: some View {
        RoundedRectangle(cornerRadius: height / 3, style: .continuous)
            .fill(Theme.placeholderFill)
            .frame(width: width, height: height)
    }
}

/// The outline of a `VideoCardView`: thumbnail, avatar and two lines of text.
struct VideoCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(Theme.placeholderFill)
                .aspectRatio(Theme.thumbnailAspectRatio, contentMode: .fit)

            HStack(alignment: .top, spacing: Theme.padding) {
                Circle()
                    .fill(Theme.placeholderFill)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 8) {
                    PlaceholderBar(height: 14)
                    PlaceholderBar(width: 190, height: 11)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.padding)
        }
        .placeholderShimmer()
        .accessibilityHidden(true)
    }
}

/// The outline of a `VideoRowView`: a 160 pt thumbnail and two lines of text.
struct VideoRowPlaceholder: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.padding) {
            RoundedRectangle(cornerRadius: Theme.thumbnailCornerRadius, style: .continuous)
                .fill(Theme.placeholderFill)
                .aspectRatio(Theme.thumbnailAspectRatio, contentMode: .fit)
                .frame(width: Theme.rowThumbnailWidth)

            VStack(alignment: .leading, spacing: 8) {
                PlaceholderBar(height: 13)
                PlaceholderBar(width: 120, height: 13)
                PlaceholderBar(width: 90, height: 10)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .placeholderShimmer()
        .accessibilityHidden(true)
    }
}

/// The outline of a `ChannelRowView`: round avatar and two lines of text.
struct ChannelRowPlaceholder: View {
    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Theme.placeholderFill)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                PlaceholderBar(width: 140, height: 15)
                PlaceholderBar(width: 100, height: 11)
            }
            Spacer(minLength: 0)
        }
        .placeholderShimmer()
        .accessibilityHidden(true)
    }
}

/// The outline of a channel page header: banner, avatar, name and a few lines.
struct ChannelHeaderPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle()
                .fill(Theme.placeholderFill)
                .aspectRatio(Theme.bannerAspectRatio, contentMode: .fit)

            HStack(spacing: 16) {
                Circle()
                    .fill(Theme.placeholderFill)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 8) {
                    PlaceholderBar(width: 150, height: 18)
                    PlaceholderBar(width: 190, height: 11)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.padding)

            VStack(alignment: .leading, spacing: 8) {
                PlaceholderBar(height: 11)
                PlaceholderBar(height: 11)
                PlaceholderBar(width: 160, height: 11)
            }
            .padding(.horizontal, Theme.padding)
        }
        .placeholderShimmer()
        .accessibilityHidden(true)
    }
}

/// The outline of a playlist page header: a 16:9 thumbnail, a title and a button.
struct PlaylistHeaderPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.placeholderFill)
                .aspectRatio(Theme.thumbnailAspectRatio, contentMode: .fit)
            PlaceholderBar(height: 20)
            PlaceholderBar(width: 180, height: 12)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.placeholderFill)
                .frame(height: 44)
        }
        .padding(.horizontal, Theme.padding)
        .placeholderShimmer()
        .accessibilityHidden(true)
    }
}

/// A few placeholder cards or rows for a list that is loading for the first time. VoiceOver reads "Loading".
struct PlaceholderList: View {
    enum Style {
        case cards, rows, channels
    }

    let style: Style
    var count = 3

    var body: some View {
        VStack(alignment: .leading, spacing: style == .cards ? Theme.feedSpacing : 16) {
            ForEach(0..<count, id: \.self) { _ in
                switch style {
                case .cards: VideoCardPlaceholder()
                case .rows: VideoRowPlaceholder()
                case .channels: ChannelRowPlaceholder()
                }
            }
        }
        .padding(.horizontal, style == .cards ? 0 : Theme.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

#Preview("Cards") {
    ScrollView { PlaceholderList(style: .cards) }
}

#Preview("Rows") {
    PlaceholderList(style: .rows, count: 4)
}

#Preview("Channel") {
    ChannelHeaderPlaceholder()
}
