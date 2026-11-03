import NoSlopKit
import SwiftUI

/// A video's title. With "De-clickbait titles" on it swaps in the community title from DeArrow once it is known;
/// until then (and whenever there is none) the original title shows.
///
/// The font is inherited, so a parent sets it: `VideoTitleText(video: v).font(.subheadline.weight(.medium))`.
struct VideoTitleText: View {
    let video: VideoSummary
    let lineLimit: Int?

    @Environment(AppEnvironment.self) private var env
    @State private var betterTitle: String?

    init(video: VideoSummary, lineLimit: Int? = 2) {
        self.video = video
        self.lineLimit = lineLimit
        // Known titles (also "none") are available on the first frame, without a flash of the original title.
        _betterTitle = State(initialValue: DeArrowTitleCache.shared.lookup(video.id)?.title)
    }

    var body: some View {
        let enabled = env.settings.deArrowTitles
        Text(enabled ? (betterTitle ?? video.title) : video.title)
            .lineLimit(lineLimit)
            .task(id: "\(video.id)|\(enabled)") { await loadBetterTitle(enabled: enabled) }
    }

    private func loadBetterTitle(enabled: Bool) async {
        guard enabled else { return }
        if let known = DeArrowTitleCache.shared.lookup(video.id) {
            betterTitle = known.title
            return
        }
        betterTitle = nil
        let title = await env.deArrow.betterTitle(videoID: video.id)
        guard !Task.isCancelled else { return }
        DeArrowTitleCache.shared.store(title, for: video.id)
        betterTitle = title
    }
}

/// Remembers DeArrow answers (including "no better title") for the session so rows scrolled back into view do not
/// ask again and do not flicker.
@MainActor
final class DeArrowTitleCache {
    static let shared = DeArrowTitleCache()

    /// `NSCache` stores objects, so the optional title is wrapped: `title == nil` means "looked up, no better title".
    final class Entry {
        let title: String?
        init(_ title: String?) { self.title = title }
    }

    private let storage: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 2_000
        return cache
    }()

    /// nil when the video was never looked up.
    func lookup(_ videoID: String) -> Entry? {
        storage.object(forKey: videoID as NSString)
    }

    func store(_ title: String?, for videoID: String) {
        storage.setObject(Entry(title), forKey: videoID as NSString)
    }
}

#Preview {
    VideoTitleText(video: SampleData.videos[0])
        .font(.subheadline.weight(.medium))
        .environment(AppEnvironment.preview())
        .padding()
}
