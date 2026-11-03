import SwiftUI

@main
struct NoSlopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let env: AppEnvironment

    init() {
        // Before anything creates `URLSession.shared`: thumbnails, avatars and API responses are cached on disk.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024, directory: nil)
        env = AppEnvironment.shared
        let environment = env
        Task { await environment.refreshAccount() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .tint(Theme.accent)
        }
    }
}
