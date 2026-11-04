#if DEBUG
import NoSlopKit
import OSLog
import UIKit

/// `-uiScript '<steps>'`: things a person does with a finger, done by the app itself at the moments the script says, for
/// simulator checks (nothing can touch the screen there). The steps run in order, separated by `;`, from the moment the
/// root view appears (alongside the links of `-openURL`):
///
///     xcrun simctl launch <udid> com.robinjungerich.noslopyt -mockServices YES -uiScript 'wait=2;tap=Account, signed out;wait=1;log=after'
///
/// - `wait=<seconds>`
/// - `tap=<label>`: a tap on the element that VoiceOver reads as `<label>`. Needs the accessibility machinery of the
///   simulator to be on, once (see `AccessibilityDump`).
/// - `pull`: pull to refresh on the biggest scroll view on screen that has a refresh control
/// - `tab=<home|subscriptions|library|search>`: a tap on a tab of the tab bar
/// - `offline=on|off`: the mock connection (`-mockOffline`) goes away or comes back
/// - `play=<sample video id>`: a tap on a row of that video (`AppEnvironment.open`, as the Up next rows do)
/// - `accountSubscribe=<sample channel id>`: the signed-in mock account subscribes to a channel behind the app's back,
///   as the viewer would on youtube.com
/// - `subscribe=<sample channel id>`, `unsubscribe=<sample channel id>`: the Subscribe button, or the swipe in the
///   subscriptions manager
/// - `log=<tag>`: one line with the state of the app: tab, the pushed screens of every tab, the player, the library
///
/// Every step writes lines that start with "[ui]" to the log (category `ui`). Compiled out of Release builds.
@MainActor
enum DebugUIScript {
    private static let log = Logger(subsystem: "com.robinjungerich.noslopyt", category: "ui")
    private static var isStarted = false

    private static let tabs: [String: AppTab] = [
        "home": .home, "subscriptions": .subscriptions, "library": .library, "search": .search,
    ]

    static func runIfRequested(in env: AppEnvironment) {
        guard !isStarted, let script = UserDefaults.standard.string(forKey: "uiScript"), !script.isEmpty else { return }
        isStarted = true
        Task { @MainActor in
            await run(script, in: env)
        }
    }

    private static func run(_ script: String, in env: AppEnvironment) async {
        for step in script.split(separator: ";") {
            let parts = step.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            if name != "wait", name != "log" {
                log.info("[ui] \(name, privacy: .public)=\(value, privacy: .public)")
            }

            switch name {
            case "wait":
                try? await Task.sleep(for: .seconds(Double(value) ?? 1))
            case "tap":
                let handled = AccessibilityDump.activate(label: value)
                log.info("[ui] tap \"\(value, privacy: .public)\" handled=\(handled)")
            case "pull":
                log.info("[ui] pull handled=\(DebugLaunchHooks.pullToRefresh())")
            case "tab":
                if let tab = tabs[value] { env.router.selectedTab = tab }
            case "offline":
                DebugLaunchHooks.mockConnection.isOnline = value != "on"
            case "play":
                if let video = SampleData.video(id: value) { env.open(video) }
            case "accountSubscribe":
                _ = try? await env.account.subscribe(channelID: value)
            case "subscribe":
                if !env.isSubscribed(value) { try? await env.toggleSubscription(Self.channel(value)) }
            case "unsubscribe":
                if env.isSubscribed(value) { try? await env.toggleSubscription(Self.channel(value)) }
            case "log":
                snapshot(value, in: env)
            default:
                log.info("[ui] unknown step \(name, privacy: .public)")
            }
        }
    }

    private static func channel(_ id: String) -> ChannelRef {
        SampleData.channel(id: id)?.ref ?? ChannelRef(id: id, name: id)
    }

    private static func snapshot(_ tag: String, in env: AppEnvironment) {
        let router = env.router
        func path(_ routes: [Route]) -> String {
            routes.isEmpty ? "-" : routes.map { String(describing: $0) }.joined(separator: ">")
        }
        let player = env.player
        log.info("""
            [ui] snapshot \(tag, privacy: .public) tab=\(String(describing: router.selectedTab), privacy: .public) \
            home=\(path(router.homePath), privacy: .public) subscriptions=\(path(router.subscriptionsPath), privacy: .public) \
            library=\(path(router.libraryPath), privacy: .public) search=\(path(router.searchPath), privacy: .public) \
            player=\(String(describing: player.presentation), privacy: .public) state=\(String(describing: player.state), privacy: .public) \
            video=\(player.currentVideo?.id ?? "-", privacy: .public) title="\(player.currentVideo?.title ?? "-", privacy: .public)" \
            channel="\(player.currentVideo?.channel?.name ?? "-", privacy: .public)" playingOffline=\(player.isPlayingOffline) \
            subscribed=\(env.library.subscriptions.map(\.id).joined(separator: ","), privacy: .public) \
            account=\(env.googleAccount?.id ?? "-", privacy: .public) online=\(DebugLaunchHooks.mockConnection.isOnline) \
            history=\(env.library.history.map(\.id).joined(separator: ","), privacy: .public) \
            linkError=\(env.linkError ?? "-", privacy: .public)
            """)
    }
}
#endif
