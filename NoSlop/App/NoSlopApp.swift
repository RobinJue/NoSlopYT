import SwiftUI

@main
struct NoSlopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let env: AppEnvironment

    init() {
        // Before anything creates `URLSession.shared`: thumbnails and avatars are cached on disk.
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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // The app is leaving the foreground (inactive on the way out, background once it is gone): whatever the
            // library still holds in memory goes to disk now, not 0.5 s from now, when iOS may have suspended the app.
            // Coming back (background, inactive, active) has nothing new to save.
            if oldPhase == .active || newPhase == .background {
                BackgroundPersistence.persist(env.library)
            }
        }
    }
}
