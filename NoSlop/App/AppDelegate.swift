import UIKit

/// Hooks SwiftUI's app lifecycle cannot express: relaunches for finished background downloads and the allowed
/// interface orientations.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunched the app because the background download session has events; hand them to the manager, which
    /// calls `completionHandler` once it has processed them.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // UIKit wants the handler called on the main thread; the download manager may call it from a session queue.
        nonisolated(unsafe) let finish = completionHandler
        AppEnvironment.shared.downloads.handleEventsForBackgroundURLSession(identifier: identifier) {
            DispatchQueue.main.async { finish() }
        }
    }

    /// Everything but upside down on iPhone (the Dynamic Island / notch sits at the top); all four on iPad.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }
}
