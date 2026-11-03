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
        .overlay { PlayerOverlayContainer() }
        .onOpenURL { url in
            Task { await env.handleOpenURL(url) }
        }
        #if DEBUG
        .task {
            if let url = LaunchURLArgument.take() {
                await env.handleOpenURL(url)
            }
        }
        #endif
    }
}

#if DEBUG
/// The debug-only `-openURL <url>` launch argument, for simulator checks. `xcrun simctl openurl` shows the iOS 26
/// "Open in No Slop?" alert for custom schemes; launching with `-openURL 'noslop://route/settings'` runs the same
/// `AppEnvironment.handleOpenURL` that `.onOpenURL` does, without the alert. Launch arguments reach
/// `UserDefaults.standard`, the same way `-mockServices YES` does. Compiled out of Release builds.
private enum LaunchURLArgument {
    private static var isTaken = false

    /// The URL to open, once per launch: nil on every later call, and when the argument is missing or not a URL.
    static func take() -> URL? {
        guard !isTaken else { return nil }
        isTaken = true
        return UserDefaults.standard.string(forKey: "openURL").flatMap { URL(string: $0) }
    }
}
#endif

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
        .tint(Theme.accent)
}
