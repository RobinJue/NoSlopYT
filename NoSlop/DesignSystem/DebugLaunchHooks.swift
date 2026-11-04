#if DEBUG
import NoSlopKit
import SwiftUI

/// Debug-only launch arguments for checking the browse screens in the simulator, where a script cannot tap or type.
/// Like `-mockServices YES` and `-openURL`, they arrive through `UserDefaults.standard`. Compiled out of Release builds.
///
/// - `-subscribeAll YES`: subscribes (locally) to every sample channel at launch, so Subscriptions has a feed in a
///   mock run.
/// - `-blockChannel '<channel id>'` (and `-blockChannelDelay <seconds>`, 6 by default): that long after launch the
///   channel is blocked the way the context menu's "Don't show this channel" does it.
/// - `-searchText '<text>'`: the Search tab submits this text when it first appears, as if it had been typed and the
///   Search key pressed.
/// - `-scrollToEnd YES`: while the mini player shows, every list that makes room for it scrolls to its end, so a
///   screenshot shows whether the last row clears the bar.
/// - `-streamDelay <seconds>`: the mock stream resolver takes that long (0.3 s by default), so a video stays in its
///   loading state long enough to look at.
/// - `-flakySponsorBlock <n>`: the first n SponsorBlock lookups of a mock run fail, the next ones answer.
/// - `-silentPlayback YES`: the player leaves the audio session alone and plays the picture without the sound. For a
///   Mac whose audio output does not answer: the simulator then waits 15 s for every audio session and audio queue it
///   starts, and playback fails with CoreMedia error -66681 after the first frame.
/// - `-assistiveTechnology YES`: the player behaves as if VoiceOver were running (the simulator cannot run it): the
///   controls stay on screen, skips are announced, the skip notice stays longer.
/// - `-seedSearches <n>`: n recent searches ("Sample search 1" ...) in the library at launch, so the list of recents
///   is longer than the screen.
/// - `-watchPage '<steps>'`: once the watch page has loaded, `scroll=<points>` scrolls it, `title` expands the title,
///   `description` expands the description and `comments` opens the Comments sheet, for example
///   `-watchPage 'scroll=700;title;description'`. Each step runs once per launch, so a page that is built again
///   starts from scratch: that is what the checks of rotation and full screen look for.
/// - `-axDump '<seconds>,...'`: that long after launch, writes the accessibility elements VoiceOver would walk through
///   to `<Documents>/ax-<seconds>.txt` (see `AccessibilityDump`).
/// - `-searchScroll <points>`: the Search tab's scroll view (results, recents, suggestions) scrolls down by that much,
///   once, a moment after it shows while no expanded player covers it. `-searchScroll end` scrolls it to its very end,
///   which also works for a `List` (it goes through UIKit's scroll view) and keeps the room the content margins leave.
/// - `-captionStyle '<parts>'`: the captions are drawn with a caption style as if the viewer had chosen it in Settings
///   > Accessibility > Subtitles & Captioning, for example `-captionStyle 'size=2;text=yellow;background=clear;edge=shadow'`
///   (see `CaptionAppearance`).
enum DebugLaunchHooks {
    private static var isPrepared = false
    private static var isSearchTextTaken = false
    private static var isSearchScrollTaken = false
    private static var takenWatchPageSteps: Set<String> = []

    static var scrollsToEnd: Bool {
        UserDefaults.standard.bool(forKey: "scrollToEnd")
    }

    /// `-silentPlayback YES`: no audio session, no audio rendition.
    static var silentPlayback: Bool {
        UserDefaults.standard.bool(forKey: "silentPlayback")
    }

    /// `-assistiveTechnology YES`: act as if VoiceOver were running.
    static var assistiveTechnology: Bool {
        UserDefaults.standard.bool(forKey: "assistiveTechnology")
    }

    /// The steps of `-watchPage`, by name (`scroll` carries its value, the others an empty string).
    static var watchPageSteps: [String: String] {
        guard let argument = UserDefaults.standard.string(forKey: "watchPage") else { return [:] }
        var steps: [String: String] = [:]
        for step in argument.split(separator: ";") {
            let parts = step.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if let name = parts.first { steps[name] = parts.count > 1 ? parts[1] : "" }
        }
        return steps
    }

    /// The value of the `-watchPage` step `name` the first time it is asked for in this launch; nil afterwards and when
    /// the argument has no such step.
    static func takeWatchPageStep(_ name: String) -> String? {
        guard let value = watchPageSteps[name], takenWatchPageSteps.insert(name).inserted else { return nil }
        return value
    }

    /// How long the mock stream resolver takes: `-streamDelay`, else its usual 0.3 s.
    static var mockStreamDelay: Duration {
        let seconds = UserDefaults.standard.double(forKey: "streamDelay")
        return seconds > 0 ? .milliseconds(Int(seconds * 1_000)) : .milliseconds(300)
    }

    /// How many SponsorBlock lookups of a mock run fail first: `-flakySponsorBlock`, else none.
    static var flakySponsorBlockFailures: Int {
        max(0, UserDefaults.standard.integer(forKey: "flakySponsorBlock"))
    }

    /// Runs `-subscribeAll` and starts the wait of `-blockChannel`, once per launch. Home calls it when it first
    /// appears, before it reads the subscriptions.
    static func prepareLaunch(in env: AppEnvironment) {
        guard !isPrepared else { return }
        isPrepared = true
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: "subscribeAll") {
            for channel in SampleData.channels where !env.library.isSubscribed(channelID: channel.id) {
                env.library.subscribe(
                    SubscribedChannel(id: channel.id, name: channel.name, avatarURL: channel.avatarURL, source: .local, subscribedAt: Date())
                )
            }
        }

        let seededSearches = defaults.integer(forKey: "seedSearches")
        if seededSearches > 0 {
            // The newest is first, so record them from the last to the first.
            for number in stride(from: seededSearches, through: 1, by: -1) {
                env.library.recordSearch("Sample search \(number)")
            }
        }

        if let id = defaults.string(forKey: "blockChannel"), !id.isEmpty {
            let delay = defaults.integer(forKey: "blockChannelDelay")
            // A task of its own, so the screen that asked can go away meanwhile (a tab switch) without cancelling it.
            Task {
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 6))
                ChannelBlocking.block(ChannelRef(id: id, name: id), using: env)
            }
        }
    }

    /// How far `-searchScroll` scrolls, once per launch; nil afterwards and without the argument.
    enum SearchScroll {
        case points(Double)
        case end
    }

    static func takeSearchScroll() -> SearchScroll? {
        guard !isSearchScrollTaken, let argument = UserDefaults.standard.string(forKey: "searchScroll") else { return nil }
        let scroll: SearchScroll
        if argument == "end" {
            scroll = .end
        } else if let points = Double(argument), points > 0 {
            scroll = .points(points)
        } else {
            return nil
        }
        isSearchScrollTaken = true
        return scroll
    }

    /// Scrolls the watch page (the biggest scroll view that starts below the player, 200 pt down the screen) to `offset`,
    /// through UIKit: nothing keeps the position afterwards, so what the page does by itself shows.
    static func scrollWatchPage(to offset: Double) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if view.isHidden || view.alpha < 0.01 { return }
            if let scrollView = view as? UIScrollView, scrollView.isScrollEnabled,
               scrollView.convert(scrollView.bounds, to: nil).minY > 200,
               scrollView.bounds.width * scrollView.bounds.height > (best.map { $0.bounds.width * $0.bounds.height } ?? 0) {
                best = scrollView
            }
            view.subviews.forEach(visit)
        }
        windows.forEach(visit)
        best?.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    }

    /// Scrolls the biggest scroll view on screen to its very end, room for the content margins included.
    static func scrollBiggestScrollViewToEnd() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if view.isHidden || view.alpha < 0.01 { return }
            if let scrollView = view as? UIScrollView, scrollView.isScrollEnabled,
               scrollView.bounds.width * scrollView.bounds.height > (best.map { $0.bounds.width * $0.bounds.height } ?? 0) {
                best = scrollView
            }
            view.subviews.forEach(visit)
        }
        windows.forEach(visit)
        guard let scrollView = best else { return }
        let inset = scrollView.adjustedContentInset
        let end = scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: max(-inset.top, end)), animated: false)
    }

    /// The text of `-searchText`, once per launch.
    static func takeSearchText() -> String? {
        guard !isSearchTextTaken else { return nil }
        isSearchTextTaken = true
        return UserDefaults.standard.string(forKey: "searchText")
    }
}

extension View {
    /// With `-scrollToEnd YES`: scrolls the scroll view inside to its end once `isMiniPlayerShowing` turns true.
    /// Without it the view is left as it is, so a normal debug run does not bind a scroll position for nothing.
    @ViewBuilder
    func debugScrollToEnd(whenMiniPlayerShows isMiniPlayerShowing: Bool) -> some View {
        if DebugLaunchHooks.scrollsToEnd {
            modifier(DebugScrollToEnd(isMiniPlayerShowing: isMiniPlayerShowing))
        } else {
            self
        }
    }
}

extension View {
    /// With `-searchScroll <points>`: scrolls the scroll view inside down by that much, once, 2.5 s after it shows
    /// without an expanded player on top of it (the results of a search take that long to arrive, and a minimized
    /// player has made its room by then). Without the argument the view is left as it is.
    @ViewBuilder
    func debugSearchScroll() -> some View {
        if UserDefaults.standard.string(forKey: "searchScroll") != nil {
            modifier(DebugSearchScroll())
        } else {
            self
        }
    }
}

private struct DebugSearchScroll: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .task(id: env.player.presentation) {
                guard env.player.presentation != .expanded else { return }
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, let scroll = DebugLaunchHooks.takeSearchScroll() else { return }
                switch scroll {
                case .points(let points): position.scrollTo(y: points)
                case .end: DebugLaunchHooks.scrollBiggestScrollViewToEnd()
                }
            }
    }
}

private struct DebugScrollToEnd: ViewModifier {
    let isMiniPlayerShowing: Bool

    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .task(id: isMiniPlayerShowing) {
                guard isMiniPlayerShowing else { return }
                // The first scroll falls short while lazy rows are still being measured and pages load: keep going.
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(800))
                    position.scrollTo(edge: .bottom)
                }
            }
    }
}
#endif
