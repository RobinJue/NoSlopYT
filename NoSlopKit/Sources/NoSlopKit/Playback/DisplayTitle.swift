import Foundation

/// The title the app shows for a video in the places that are not SwiftUI views: the lock screen, Control Center, AirPlay
/// and CarPlay, and the spoken label of the mini player.
///
/// The views show the community title from DeArrow when "De-clickbait titles" is on and one exists
/// (`VideoTitleText`); everything that talks about the video must say the same title.
public enum DisplayTitle {
    /// `better` when De-clickbait titles is on and there is a real one (not blank), else `original`.
    public static func resolve(original: String, better: String?, deArrowEnabled: Bool) -> String {
        guard deArrowEnabled, let better, !better.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return original
        }
        return better
    }
}
