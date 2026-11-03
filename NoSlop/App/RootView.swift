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
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
        .tint(Theme.accent)
}
