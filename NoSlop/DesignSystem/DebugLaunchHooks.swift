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
enum DebugLaunchHooks {
    private static var isPrepared = false
    private static var isSearchTextTaken = false

    static var scrollsToEnd: Bool {
        UserDefaults.standard.bool(forKey: "scrollToEnd")
    }

    /// `-silentPlayback YES`: no audio session, no audio rendition.
    static var silentPlayback: Bool {
        UserDefaults.standard.bool(forKey: "silentPlayback")
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

        if let id = defaults.string(forKey: "blockChannel"), !id.isEmpty {
            let delay = defaults.integer(forKey: "blockChannelDelay")
            // A task of its own, so the screen that asked can go away meanwhile (a tab switch) without cancelling it.
            Task {
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 6))
                ChannelBlocking.block(ChannelRef(id: id, name: id), using: env)
            }
        }
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
