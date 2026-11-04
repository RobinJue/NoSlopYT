import NoSlopKit
import SwiftUI

/// The four tabs, each with its own `NavigationStack` bound to the router, with the player on top of everything.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var router = env.router

        TabView(selection: $router.selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView()
                        .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
                }
            }

            Tab("Subscriptions", systemImage: "play.square.stack", value: AppTab.subscriptions) {
                NavigationStack(path: $router.subscriptionsPath) {
                    SubscriptionsView()
                        .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
                }
            }

            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView()
                        .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
                }
            }

            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
                }
            }
        }
        // While the player panel covers the tabs, VoiceOver has no business in them: the tab bar, the navigation bars
        // and the lists are hidden from it. (Before `.overlay`: after it, the panel would be hidden as well.)
        .accessibilityHidden(env.player.presentation == .expanded)
        .overlay { PlayerOverlayContainer() }
        .onOpenURL { url in
            Task { await env.handleOpenURL(url) }
        }
        .alert(
            "Can't open this link",
            isPresented: Binding(
                get: { env.linkError != nil },
                set: { if !$0 { env.dismissLinkError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(env.linkError ?? "")
        }
        #if DEBUG
        .task {
            AccessibilityDump.runIfRequested()
            DebugUIScript.runIfRequested(in: env)
            await LaunchURLArgument.openAll(in: env)
        }
        #endif
    }
}

#if DEBUG
/// The debug-only `-openURL <links>` launch argument, for simulator checks. `xcrun simctl openurl` shows the iOS 26
/// "Open in No Slop?" alert for custom schemes; launching with `-openURL 'noslop://route/settings'` runs the same
/// `AppEnvironment.handleOpenURL` that `.onOpenURL` does, without the alert.
///
/// Several links go in one argument, separated by " | " (space, pipe, space), and are handled in order:
/// `-openURL 'noslop://watch?v=aqz-KE-bpKQ | noslop://tab/library'`. The first runs as soon as the root view appears;
/// each following one runs `linkInterval` after the one before it was handled, so the screen has settled (the player
/// expanded, a tab switched) when the next link arrives. A link that needs a space or a pipe of its own writes it
/// percent-encoded (`%20`, `%7C`), as any URL does. A piece that is not a URL is skipped.
///
/// Launch arguments reach `UserDefaults.standard`, the same way `-mockServices YES` does. Compiled out of Release builds.
private enum LaunchURLArgument {
    private static var isTaken = false

    /// Between two links in the argument.
    static let separator = " | "
    /// From one link having been handled to the next one starting.
    static let linkInterval: Duration = .seconds(1.5)

    /// The links to open, in order, once per launch: empty on every later call, and when the argument is missing.
    static func take() -> [URL] {
        guard !isTaken else { return [] }
        isTaken = true
        return links(in: UserDefaults.standard.string(forKey: "openURL"))
    }

    /// `argument` cut at `separator`; the pieces that are not URLs (an empty one, say) are dropped. An argument
    /// without a separator is one piece, so a single link goes to `URL(string:)` exactly as written.
    static func links(in argument: String?) -> [URL] {
        guard let argument else { return [] }
        return argument.components(separatedBy: separator).compactMap { URL(string: $0) }
    }

    /// Opens the links of the launch argument through `env`, the way `.onOpenURL` does. Stops when the task is
    /// cancelled (the root view going away); the links that have not run yet are dropped with it.
    static func openAll(in env: AppEnvironment) async {
        for (index, url) in take().enumerated() {
            if index > 0 {
                do {
                    try await Task.sleep(for: linkInterval)
                } catch {
                    return
                }
            }
            await env.handleOpenURL(url)
        }
    }
}
#endif

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
        .tint(Theme.accent)
}
