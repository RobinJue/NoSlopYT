import NoSlopKit
import SwiftUI

/// A 16:9 video thumbnail with the badges YouTube shows on it: duration (or LIVE / UPCOMING), a red watch-progress
/// bar along the bottom edge, and a marker when the video is downloaded.
///
/// It fills the width its parent offers; the parent decides the width and the corner radius.
struct ThumbnailView: View {
    let video: VideoSummary

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        RemoteImage(url: imageURL, contentMode: .fill)
            .aspectRatio(Theme.thumbnailAspectRatio, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) { statusBadge }
            .overlay(alignment: .bottomLeading) { downloadedBadge }
            .overlay(alignment: .bottom) { progressBar }
    }

    /// 480 px wide is sharp enough for a full-width card and plenty for a 160 pt row.
    private var imageURL: URL? {
        video.displayThumbnails.best(minWidth: 480)?.url
    }

    // MARK: Badges

    @ViewBuilder
    private var statusBadge: some View {
        if video.isLive {
            badge("LIVE", background: Theme.accent)
        } else if video.isUpcoming {
            badge("UPCOMING", background: Theme.badgeBackground)
        } else if let seconds = video.durationSeconds, seconds > 0 {
            badge(DurationFormatter.string(seconds: seconds), background: Theme.badgeBackground)
        }
    }

    private func badge(_ text: String, background: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(6)
            // The thumbnail is hidden from VoiceOver; the card reads title, channel and age instead.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var downloadedBadge: some View {
        if env.downloads.completedItem(videoID: video.id) != nil {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Theme.badgeBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(6)
                .accessibilityLabel("Downloaded")
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = watchedFraction {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.35))
                    Rectangle().fill(Theme.accent).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }

    /// How much of the video was watched (0...1), nil when it was not started or the length is unknown.
    private var watchedFraction: Double? {
        guard let entry = env.library.progress(for: video.id), entry.progressSeconds > 0 else { return nil }
        let length = entry.durationSeconds ?? video.durationSeconds.map(Double.init) ?? 0
        guard length > 0 else { return nil }
        return min(1, max(0, entry.progressSeconds / length))
    }
}

#Preview {
    ThumbnailView(video: SampleData.videos[0])
        .environment(AppEnvironment.preview())
        .padding()
}
