import NoSlopKit
import Observation
import SwiftUI

/// A video's title. With "De-clickbait titles" on it swaps in the community title from DeArrow once it is known;
/// until then (and whenever there is none, or the lookup did not work) the original title shows.
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
        _betterTitle = State(initialValue: DeArrowTitleCache.shared.knownTitle(for: video.id))
    }

    var body: some View {
        let enabled = env.settings.deArrowTitles
        // Lookups that failed are asked again when the cache says so (the connection is back, the setting was switched).
        let retry = DeArrowTitleCache.shared.retryCount
        Text(enabled ? (betterTitle ?? video.title) : video.title)
            .lineLimit(lineLimit)
            .task(id: "\(video.id)|\(enabled)|\(retry)") { await loadBetterTitle(enabled: enabled) }
    }

    private func loadBetterTitle(enabled: Bool) async {
        guard enabled else { return }
        switch DeArrowTitleCache.shared.recall(video.id) {
        case .answer(let known):
            betterTitle = known
            return
        case .waiting:
            // Asked a moment ago and it failed: the original shows, and the next appearance after the wait asks again.
            betterTitle = nil
            return
        case .unknown:
            break
        }
        betterTitle = nil
        let lookup = await env.deArrow.lookup(videoID: video.id)
        // The answer belongs to the video, not to this card: it is kept even when the card has left the screen by now (the
        // request itself is not cancelled with it). Otherwise a feed scrolled through a slow connection would never learn
        // that its lookups failed, and ask again for every card that comes back. Remembers titles and "none"; a lookup that
        // failed is not an answer and only keeps the video from being asked again for a minute.
        DeArrowTitleCache.shared.record(lookup, for: video.id)
        guard !Task.isCancelled else { return }
        if case .title(let title) = lookup {
            betterTitle = title
        }
    }
}

/// Remembers DeArrow's answers (a community title, or "there is none") for the session so rows scrolled back into view do
/// not ask again and do not flicker. A lookup that failed is not an answer: it only keeps the card from asking again for a
/// minute (`DeArrowAnswers` has the rules), so that the titles come back when the connection does.
@MainActor
@Observable
final class DeArrowTitleCache {
    static let shared = DeArrowTitleCache()

    @ObservationIgnored private var answers = DeArrowAnswers()

    /// Counts the times the wait after a failed lookup was ended early (`retryFailedLookups`). The title views take it into
    /// their task id, so the ones on screen ask again at once.
    private(set) var retryCount = 0

    /// What is known about the video: an answer, "wait", or nothing yet.
    func recall(_ videoID: String) -> DeArrowAnswers.Recall {
        answers.recall(videoID)
    }

    /// The community title when DeArrow has given one; nil for "none", for a lookup that failed and for a video never asked.
    func knownTitle(for videoID: String) -> String? {
        if case .answer(let title) = answers.recall(videoID) { return title }
        return nil
    }

    func record(_ lookup: DeArrowLookup, for videoID: String) {
        answers.record(lookup, for: videoID)
    }

    /// The connection is back, or "De-clickbait titles" was switched on: the videos whose lookup failed are asked about
    /// again, also the ones that are on screen, instead of after their wait.
    func retryFailedLookups() {
        if answers.forgetFailures() {
            retryCount += 1
        }
    }
}

#Preview {
    VideoTitleText(video: SampleData.videos[0])
        .font(.subheadline.weight(.medium))
        .environment(AppEnvironment.preview())
        .padding()
}
